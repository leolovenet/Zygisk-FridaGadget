LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := zygiskfridagadget
LOCAL_SRC_FILES := main.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)
LOCAL_LDLIBS := -llog -ldl
LOCAL_CPPFLAGS := -std=c++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics -Wall -Wextra

include $(BUILD_SHARED_LIBRARY)
