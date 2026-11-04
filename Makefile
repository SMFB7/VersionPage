TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
# Remove this line if you're on a rootful jailbreak (checkra1n, unc0ver, palera1n rootful)
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VersionPage
VersionPage_FILES = Tweak.x
VersionPage_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
VersionPage_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk
