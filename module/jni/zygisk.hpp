#ifndef ZYGISK_HPP
#define ZYGISK_HPP

#include <jni.h>
#include <stdint.h>
#include <sys/types.h>

#define ZYGISK_API_VERSION 4

namespace zygisk {

struct Api;
struct AppSpecializeArgs;
struct ServerSpecializeArgs;

class ModuleBase {
public:
    virtual void onLoad(Api *, JNIEnv *) {}
    virtual void preAppSpecialize(AppSpecializeArgs *) {}
    virtual void postAppSpecialize(const AppSpecializeArgs *) {}
    virtual void preServerSpecialize(ServerSpecializeArgs *) {}
    virtual void postServerSpecialize(const ServerSpecializeArgs *) {}
};

struct AppSpecializeArgs {
    jint &uid;
    jint &gid;
    jintArray &gids;
    jint &runtime_flags;
    jobjectArray &rlimits;
    jint &mount_external;
    jstring &se_info;
    jstring &nice_name;
    jstring &instruction_set;
    jstring &app_data_dir;
    jintArray *const fds_to_ignore;
    jboolean *const is_child_zygote;
    jboolean *const is_top_app;
    jobjectArray *const pkg_data_info_list;
    jobjectArray *const whitelisted_data_info_list;
    jboolean *const mount_data_dirs;
    jboolean *const mount_storage_dirs;

    AppSpecializeArgs() = delete;
};

struct ServerSpecializeArgs {
    jint &uid;
    jint &gid;
    jintArray &gids;
    jint &runtime_flags;
    jlong &permitted_capabilities;
    jlong &effective_capabilities;

    ServerSpecializeArgs() = delete;
};

enum Option : int {
    FORCE_DENYLIST_UNMOUNT = 0,
    DLCLOSE_MODULE_LIBRARY = 1,
};

enum StateFlag : uint32_t {
    PROCESS_GRANTED_ROOT = (1u << 0),
    PROCESS_ON_DENYLIST = (1u << 1),
};

namespace internal {

struct module_abi {
    long api_version;
    ModuleBase *impl;
    void (*preAppSpecialize)(ModuleBase *, AppSpecializeArgs *);
    void (*postAppSpecialize)(ModuleBase *, const AppSpecializeArgs *);
    void (*preServerSpecialize)(ModuleBase *, ServerSpecializeArgs *);
    void (*postServerSpecialize)(ModuleBase *, const ServerSpecializeArgs *);

    explicit module_abi(ModuleBase *module) : api_version(ZYGISK_API_VERSION), impl(module) {
        preAppSpecialize = [](ModuleBase *m, AppSpecializeArgs *args) {
            m->preAppSpecialize(args);
        };
        postAppSpecialize = [](ModuleBase *m, const AppSpecializeArgs *args) {
            m->postAppSpecialize(args);
        };
        preServerSpecialize = [](ModuleBase *m, ServerSpecializeArgs *args) {
            m->preServerSpecialize(args);
        };
        postServerSpecialize = [](ModuleBase *m, const ServerSpecializeArgs *args) {
            m->postServerSpecialize(args);
        };
    }
};

struct api_table {
    void *impl;
    bool (*registerModule)(api_table *, module_abi *);
    void (*hookJniNativeMethods)(JNIEnv *, const char *, JNINativeMethod *, int);
    void (*pltHookRegister)(dev_t, ino_t, const char *, void *, void **);
    bool (*exemptFd)(int);
    bool (*pltHookCommit)();
    int (*connectCompanion)(void *);
    void (*setOption)(void *, Option);
    int (*getModuleDir)(void *);
    uint32_t (*getFlags)(void *);
};

template <class T>
void entry_impl(api_table *table, JNIEnv *env);

}  // namespace internal

struct Api {
    int connectCompanion() {
        return tbl->connectCompanion != 0 ? tbl->connectCompanion(tbl->impl) : -1;
    }

    int getModuleDir() {
        return tbl->getModuleDir != 0 ? tbl->getModuleDir(tbl->impl) : -1;
    }

    void setOption(Option opt) {
        if (tbl->setOption != 0) {
            tbl->setOption(tbl->impl, opt);
        }
    }

    uint32_t getFlags() {
        return tbl->getFlags != 0 ? tbl->getFlags(tbl->impl) : 0;
    }

    bool exemptFd(int fd) {
        return tbl->exemptFd != 0 && tbl->exemptFd(fd);
    }

    void hookJniNativeMethods(JNIEnv *env, const char *className,
                              JNINativeMethod *methods, int numMethods) {
        if (tbl->hookJniNativeMethods != 0) {
            tbl->hookJniNativeMethods(env, className, methods, numMethods);
        }
    }

    void pltHookRegister(dev_t dev, ino_t inode, const char *symbol,
                         void *newFunc, void **oldFunc) {
        if (tbl->pltHookRegister != 0) {
            tbl->pltHookRegister(dev, inode, symbol, newFunc, oldFunc);
        }
    }

    bool pltHookCommit() {
        return tbl->pltHookCommit != 0 && tbl->pltHookCommit();
    }

private:
    internal::api_table *tbl;

    template <class T>
    friend void internal::entry_impl(internal::api_table *, JNIEnv *);
};

namespace internal {

template <class T>
void entry_impl(api_table *table, JNIEnv *env) {
    static Api api;
    api.tbl = table;

    static T module;
    ModuleBase *module_base = &module;
    static module_abi abi(module_base);

    if (!table->registerModule(table, &abi)) {
        return;
    }

    module_base->onLoad(&api, env);
}

}  // namespace internal

}  // namespace zygisk

#define REGISTER_ZYGISK_MODULE(clazz)                                      \
    extern "C" __attribute__((visibility("default")))                     \
    void zygisk_module_entry(zygisk::internal::api_table *table,           \
                             JNIEnv *env) {                                \
        zygisk::internal::entry_impl<clazz>(table, env);                   \
    }

#endif
