#include <jni.h>
#include <android/log.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "zygisk.hpp"

#define LOG_TAG "ZygiskFridaGadget"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

enum MatchMode {
    MATCH_EXACT = 0,
    MATCH_PREFIX = 1,
    MATCH_SUFFIX = 2,
    MATCH_CONTAINS = 3,
};

static const char *TARGETS_CONFIG_PATH = "targets.conf";
static const char *MODULE_CONFIG_PATH = "module.conf";
static const char *PAYLOAD_NAME = "libgadget.so";
static const uint32_t COMPANION_OP_READ_FILE = 1;
static const uint32_t MODULE_FILE_MAX_SIZE = 1024 * 1024;

static bool isAllowedModuleFile(const char *path) {
    return strcmp(path, TARGETS_CONFIG_PATH) == 0 || strcmp(path, MODULE_CONFIG_PATH) == 0;
}

static bool readExact(int fd, void *buffer, size_t size) {
    char *cursor = static_cast<char *>(buffer);
    size_t done = 0;
    while (done < size) {
        ssize_t len = read(fd, cursor + done, size - done);
        if (len <= 0) {
            return false;
        }
        done += static_cast<size_t>(len);
    }
    return true;
}

static bool writeExact(int fd, const void *buffer, size_t size) {
    const char *cursor = static_cast<const char *>(buffer);
    size_t done = 0;
    while (done < size) {
        ssize_t len = write(fd, cursor + done, size - done);
        if (len <= 0) {
            return false;
        }
        done += static_cast<size_t>(len);
    }
    return true;
}

static int readModuleFileFromFd(int moduleDir, const char *path, char **out) {
    if (!isAllowedModuleFile(path)) {
        return -1;
    }

    int fd = openat(moduleDir, path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }

    size_t capacity = 4096;
    size_t used = 0;
    char *data = static_cast<char *>(malloc(capacity + 1));
    if (data == 0) {
        close(fd);
        return -1;
    }

    for (;;) {
        if (used == capacity) {
            if (capacity >= MODULE_FILE_MAX_SIZE) {
                free(data);
                close(fd);
                return -1;
            }

            size_t nextCapacity = capacity * 2;
            char *next = static_cast<char *>(realloc(data, nextCapacity + 1));
            if (next == 0) {
                free(data);
                close(fd);
                return -1;
            }
            data = next;
            capacity = nextCapacity;
        }

        ssize_t len = read(fd, data + used, capacity - used);
        if (len < 0) {
            free(data);
            close(fd);
            return -1;
        }
        if (len == 0) {
            break;
        }
        used += static_cast<size_t>(len);
    }

    close(fd);
    if (used == 0) {
        free(data);
        return -1;
    }

    data[used] = 0;
    *out = data;
    return static_cast<int>(used);
}

class ZygiskFridaGadget : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        shouldLoad = false;
        loadModuleConfig();

        if (args == 0 || args->nice_name == 0) {
            logDebug("process name: <null>");
            if (api != 0) {
                api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            }
            return;
        }

        JNIEnv *jni = env;
        if (jni == 0) {
            logDebug("process name: <no-jni-env>");
            if (api != 0) {
                api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            }
            return;
        }

        const char *process_name = jni->GetStringUTFChars(args->nice_name, 0);
        if (process_name == 0) {
            logDebug("process name: <utf-failed>");
            if (api != 0) {
                api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            }
            return;
        }

        logDebug("process name: %s", process_name);

        if (findMatchingTarget(process_name)) {
            shouldLoad = true;
        } else {
            logDebug("target not matched");
            if (api != 0) {
                api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            }
        }

        jni->ReleaseStringUTFChars(args->nice_name, process_name);
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        (void) args;

        if (!shouldLoad) {
            return;
        }

        if (payloadPath[0] == 0) {
            LOGE("dlopen failed: payload path is empty");
            return;
        }

        if (isGadgetAlreadyLoaded(payloadPath)) {
            LOGI("payload already loaded, skip dlopen: %s", payloadPath);
            return;
        }

        LOGI("start loading payload: %s", payloadPath);

        dlerror();
        void *handle = dlopen(payloadPath, RTLD_NOW | RTLD_GLOBAL);
        if (handle == 0) {
            const char *error = dlerror();
            LOGE("dlopen failed: %s", error != 0 ? error : "unknown error");
            return;
        }

        LOGI("dlopen success: payload loaded successfully");
    }

private:
    static bool hasSuffix(const char *value, const char *suffix) {
        size_t valueLen = strlen(value);
        size_t suffixLen = strlen(suffix);
        if (suffixLen > valueLen) {
            return false;
        }
        return strcmp(value + valueLen - suffixLen, suffix) == 0;
    }

    static bool hasPrefix(const char *value, const char *prefix) {
        return strncmp(value, prefix, strlen(prefix)) == 0;
    }

    static bool contains(const char *value, const char *needle) {
        return strstr(value, needle) != 0;
    }

    void logDebug(const char *fmt, ...) {
        if (!debugEnabled) {
            return;
        }

        va_list args;
        va_start(args, fmt);
        __android_log_vprint(ANDROID_LOG_INFO, LOG_TAG, fmt, args);
        va_end(args);
    }

    static bool parseMatchMode(const char *mode, MatchMode *out) {
        if (strcmp(mode, "exact") == 0) {
            *out = MATCH_EXACT;
            return true;
        }
        if (strcmp(mode, "prefix") == 0) {
            *out = MATCH_PREFIX;
            return true;
        }
        if (strcmp(mode, "suffix") == 0) {
            *out = MATCH_SUFFIX;
            return true;
        }
        if (strcmp(mode, "contains") == 0) {
            *out = MATCH_CONTAINS;
            return true;
        }
        return false;
    }

    static bool matchesProcessName(const char *processName, const char *targetProcess,
                                   MatchMode matchMode) {
        switch (matchMode) {
            case MATCH_EXACT:
                return strcmp(processName, targetProcess) == 0;
            case MATCH_PREFIX:
                return hasPrefix(processName, targetProcess);
            case MATCH_SUFFIX:
                return hasSuffix(processName, targetProcess);
            case MATCH_CONTAINS:
                return contains(processName, targetProcess);
            default:
                return false;
        }
    }

    static bool fileExists(const char *path) {
        return access(path, R_OK) == 0;
    }

    static bool isGadgetAlreadyLoaded(const char *payloadPath) {
        if (payloadPath == 0 || payloadPath[0] == 0) {
            return false;
        }

        FILE *fp = fopen("/proc/self/maps", "re");
        if (fp == 0) {
            return false;
        }

        char line[1024];
        while (fgets(line, sizeof(line), fp) != 0) {
            if (strstr(line, payloadPath) != 0) {
                fclose(fp);
                return true;
            }
        }

        fclose(fp);
        return false;
    }

    bool readModuleFile(const char *path, char *out, size_t outSize) {
        char *data = readModuleFileAlloc(path);
        if (data == 0) {
            return false;
        }

        size_t len = strlen(data);
        if (len == 0 || len >= outSize) {
            free(data);
            return false;
        }

        memcpy(out, data, len + 1);
        free(data);
        return true;
    }

    char *readModuleFileViaCompanion(const char *path) {
        if (api == 0) {
            return 0;
        }

        if (!isAllowedModuleFile(path)) {
            return 0;
        }

        int fd = api->connectCompanion();
        if (fd < 0) {
            return 0;
        }

        uint32_t op = COMPANION_OP_READ_FILE;
        uint32_t pathLen = static_cast<uint32_t>(strlen(path));
        if (!writeExact(fd, &op, sizeof(op)) ||
            !writeExact(fd, &pathLen, sizeof(pathLen)) ||
            !writeExact(fd, path, pathLen)) {
            close(fd);
            return 0;
        }

        int32_t status = -1;
        uint32_t size = 0;
        if (!readExact(fd, &status, sizeof(status)) ||
            !readExact(fd, &size, sizeof(size)) ||
            status != 0 || size == 0 || size > MODULE_FILE_MAX_SIZE) {
            close(fd);
            return 0;
        }

        char *data = static_cast<char *>(malloc(size + 1));
        if (data == 0) {
            close(fd);
            return 0;
        }

        if (!readExact(fd, data, size)) {
            free(data);
            close(fd);
            return 0;
        }
        close(fd);

        data[size] = 0;
        return data;
    }

    char *readModuleFileAlloc(const char *path) {
        char *data = readModuleFileViaCompanion(path);
        if (data != 0) {
            return data;
        }

        if (api == 0) {
            return 0;
        }

        int moduleDir = api->getModuleDir();
        if (moduleDir < 0) {
            return 0;
        }

        if (readModuleFileFromFd(moduleDir, path, &data) <= 0) {
            return 0;
        }

        return data;
    }

    void loadModuleConfig() {
        if (debugLoaded) {
            return;
        }

        debugLoaded = true;
        debugEnabled = false;

        char config[256];
        if (!readModuleFile(MODULE_CONFIG_PATH, config, sizeof(config))) {
            return;
        }

        if (strstr(config, "debug=1") != 0 || strstr(config, "debug=true") != 0) {
            debugEnabled = true;
        }
    }

    static bool writeCandidate(char *out, size_t outSize, const char *dir) {
        int written = snprintf(out, outSize, "%s/%s", dir, PAYLOAD_NAME);
        if (written <= 0 || (size_t) written >= outSize) {
            return false;
        }
        return fileExists(out);
    }

    static bool checkLibDir(char *out, size_t outSize, const char *appDir, const char *abiDir) {
        char dir[512];
        int written = snprintf(dir, sizeof(dir), "%s/%s", appDir, abiDir);
        return written > 0 && (size_t) written < sizeof(dir) && writeCandidate(out, outSize, dir);
    }

    static bool checkLibDirs(char *out, size_t outSize, const char *appDir) {
        if (sizeof(void *) == 8) {
            if (checkLibDir(out, outSize, appDir, "lib/arm64")) {
                return true;
            }
        } else if (checkLibDir(out, outSize, appDir, "lib/arm")) {
            return true;
        }

        return checkLibDir(out, outSize, appDir, "lib");
    }

    static bool isPackageAppDirName(const char *name, const char *packageName) {
        size_t packageLen = strlen(packageName);
        if (strncmp(name, packageName, packageLen) != 0) {
            return false;
        }

        char boundary = name[packageLen];
        return boundary == 0 || boundary == '-';
    }

    static const char *baseName(const char *path) {
        const char *slash = strrchr(path, '/');
        return slash == 0 ? path : slash + 1;
    }

    static bool checkAppDirFromPath(char *out, size_t outSize, const char *path,
                                    const char *packageName) {
        char appDir[512];
        const char *baseApk = strstr(path, "/base.apk");
        const char *libDir = strstr(path, "/lib/");
        const char *end = 0;

        if (baseApk != 0) {
            end = baseApk;
        } else if (libDir != 0) {
            end = libDir;
        } else {
            return false;
        }

        size_t len = (size_t) (end - path);
        if (len == 0 || len >= sizeof(appDir)) {
            return false;
        }

        memcpy(appDir, path, len);
        appDir[len] = 0;
        if (!isPackageAppDirName(baseName(appDir), packageName)) {
            return false;
        }
        return checkLibDirs(out, outSize, appDir);
    }

    static bool findPayloadPathFromMaps(char *out, size_t outSize, const char *packageName) {
        FILE *fp = fopen("/proc/self/maps", "re");
        if (fp == 0) {
            return false;
        }

        char line[1024];
        while (fgets(line, sizeof(line), fp) != 0) {
            char *path = strstr(line, "/data/app/");
            if (path == 0) {
                continue;
            }

            char *newline = strchr(path, '\n');
            if (newline != 0) {
                *newline = 0;
            }

            if (checkAppDirFromPath(out, outSize, path, packageName)) {
                fclose(fp);
                return true;
            }
        }

        fclose(fp);
        return false;
    }

    static bool scanDataAppForPackage(char *out, size_t outSize, const char *base,
                                      const char *packageName, int depth) {
        if (depth > 3) {
            return false;
        }

        DIR *dir = opendir(base);
        if (dir == 0) {
            return false;
        }

        struct dirent *entry;
        while ((entry = readdir(dir)) != 0) {
            const char *name = entry->d_name;
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
                continue;
            }

            char path[512];
            int written = snprintf(path, sizeof(path), "%s/%s", base, name);
            if (written <= 0 || (size_t) written >= sizeof(path)) {
                continue;
            }

            if (isPackageAppDirName(name, packageName) && checkLibDirs(out, outSize, path)) {
                closedir(dir);
                return true;
            }

            if (entry->d_type == DT_DIR || entry->d_type == DT_UNKNOWN) {
                if (scanDataAppForPackage(out, outSize, path, packageName, depth + 1)) {
                    closedir(dir);
                    return true;
                }
            }
        }

        closedir(dir);
        return false;
    }

    static bool findPayloadPath(char *out, size_t outSize, const char *packageName) {
        if (findPayloadPathFromMaps(out, outSize, packageName)) {
            LOGI("payload path resolved from maps");
            return true;
        }

        if (scanDataAppForPackage(out, outSize, "/data/app", packageName, 0)) {
            LOGI("payload path resolved from /data/app scan");
            return true;
        }

        return false;
    }

    static char *nextField(char **cursor) {
        if (*cursor == 0) {
            return 0;
        }

        char *field = *cursor;
        char *sep = strchr(field, '|');
        if (sep != 0) {
            *sep = 0;
            *cursor = sep + 1;
        } else {
            *cursor = 0;
        }
        return field;
    }

    static char *trimField(char *field) {
        while (*field == ' ' || *field == '\t' || *field == '\r') {
            field++;
        }

        char *end = field + strlen(field);
        while (end > field && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) {
            end--;
        }
        *end = 0;
        return field;
    }

    bool parseConfigLine(char *line, const char *processName) {
        char *cursor = line;
        char *packageName = trimField(nextField(&cursor));
        char *targetProcess = nextField(&cursor);
        char *match = nextField(&cursor);
        char *abi = nextField(&cursor);
        char *extra = nextField(&cursor);

        (void) abi;

        if (packageName == 0 || packageName[0] == 0 || packageName[0] == '#') {
            return false;
        }

        if (extra != 0 && trimField(extra)[0] != 0) {
            LOGE("invalid targets.conf line for package=%s: too many fields", packageName);
            return false;
        }

        targetProcess = targetProcess == 0 ? packageName : trimField(targetProcess);
        if (targetProcess[0] == 0) {
            targetProcess = packageName;
        }

        match = match == 0 ? const_cast<char *>("exact") : trimField(match);
        if (match[0] == 0) {
            match = const_cast<char *>("exact");
        }

        MatchMode matchMode;
        if (!parseMatchMode(match, &matchMode)) {
            LOGE("invalid match mode in targets.conf: package=%s match=%s", packageName, match);
            return false;
        }

        if (!matchesProcessName(processName, targetProcess, matchMode)) {
            return false;
        }

        if (!findPayloadPath(payloadPath, sizeof(payloadPath), packageName)) {
            LOGE("target matched but payload path could not be resolved: process=%s package=%s",
                 processName, packageName);
            return false;
        }

        LOGI("target matched: process=%s package=%s target_process=%s match=%s",
             processName, packageName, targetProcess, match);
        return true;
    }

    bool findMatchingTarget(const char *processName) {
        char *config = readModuleFileAlloc(TARGETS_CONFIG_PATH);
        if (config == 0) {
            LOGE("target config not found: %s", TARGETS_CONFIG_PATH);
            return false;
        }

        bool matched = false;
        char *line = config;
        while (line != 0 && *line != 0) {
            char *next = strchr(line, '\n');
            if (next != 0) {
                *next = 0;
                next++;
            }

            if (*line != 0 && parseConfigLine(line, processName)) {
                matched = true;
                break;
            }

            line = next;
        }

        free(config);
        return matched;
    }
    zygisk::Api *api = 0;
    JNIEnv *env = 0;
    char payloadPath[512] = {0};
    bool shouldLoad = false;
    bool debugLoaded = false;
    bool debugEnabled = false;
};

extern "C" __attribute__((visibility("default"))) __attribute__((used))
void zygisk_companion_entry(int client) {
    uint32_t op = 0;
    uint32_t pathLen = 0;
    int32_t status = -1;
    uint32_t size = 0;

    if (!readExact(client, &op, sizeof(op)) ||
        !readExact(client, &pathLen, sizeof(pathLen)) ||
        op != COMPANION_OP_READ_FILE ||
        pathLen == 0 || pathLen > 128) {
        writeExact(client, &status, sizeof(status));
        writeExact(client, &size, sizeof(size));
        close(client);
        return;
    }

    char path[129];
    if (!readExact(client, path, pathLen)) {
        writeExact(client, &status, sizeof(status));
        writeExact(client, &size, sizeof(size));
        close(client);
        return;
    }
    path[pathLen] = 0;

    char *data = 0;
    int len = readModuleFileFromFd(AT_FDCWD, path, &data);
    if (len > 0 && data != 0) {
        status = 0;
        size = static_cast<uint32_t>(len);
        writeExact(client, &status, sizeof(status));
        writeExact(client, &size, sizeof(size));
        writeExact(client, data, size);
        free(data);
    } else {
        writeExact(client, &status, sizeof(status));
        writeExact(client, &size, sizeof(size));
    }

    close(client);
}

REGISTER_ZYGISK_MODULE(ZygiskFridaGadget)
