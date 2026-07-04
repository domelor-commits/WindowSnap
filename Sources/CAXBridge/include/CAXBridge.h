#ifndef CAXBRIDGE_H
#define CAXBRIDGE_H

#include <ApplicationServices/ApplicationServices.h>

// Private but long-stable Accessibility SPI that maps an AXUIElement to its
// CoreGraphics window id (CGWindowID). Used to give each window a per-session
// stable identifier that does not change when a window's title changes.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

#endif
