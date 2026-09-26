/* A no-op FBInk so KPM's CLI links on a Linux host; the CLI only calls it behind --fbink. */
#ifndef KPM_TEST_FBINK_STUB_H
#define KPM_TEST_FBINK_STUB_H

#include <stdbool.h>
#include <stdint.h>

typedef enum { WFM_AUTO = 0 } WFM_MODE_INDEX_E;

typedef struct {
    short int row;
    short int voffset;
    bool is_verbose;
    bool is_quiet;
    WFM_MODE_INDEX_E wfm_mode;
    bool no_refresh;
    bool is_cleared;
    uint8_t fontmult;
} FBInkConfig;

typedef struct {
    uint8_t fontsize_mult;
    uint32_t screen_width;
    uint32_t screen_height;
} FBInkState;

typedef struct {
    uint16_t left;
    uint16_t top;
    uint16_t width;
    uint16_t height;
} FBInkRect;

int fbink_open(void);
int fbink_init(int fbfd, const FBInkConfig* config);
int fbink_get_state(const FBInkConfig* config, FBInkState* state);
int fbink_cls(int fbfd, const FBInkConfig* config, const FBInkRect* rect, bool no_rota);
int fbink_refresh(int fbfd, uint32_t top, uint32_t left, uint32_t width, uint32_t height,
                  const FBInkConfig* config);
int fbink_print(int fbfd, const char* string, const FBInkConfig* config);
int fbink_close(int fbfd);

#endif
