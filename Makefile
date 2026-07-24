TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES := mediaserverd SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyVCAM
MyVCAM_FILES = Tweak.x MyVCAMWebSocket.m CameraInjector.m SpringBoardUI.m
MyVCAM_CFLAGS = -fobjc-arc -I.
MyVCAM_LDFLAGS = -framework Foundation -framework UIKit -framework QuartzCore -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework IOSurface -framework Metal

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall mediaserverd"
	install.exec "killall SpringBoard"
