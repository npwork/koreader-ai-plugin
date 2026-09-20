#include "fbink.h"

int fbink_open(void) { return -1; }
int fbink_init(int fbfd, const FBInkConfig* config) { (void)fbfd; (void)config; return -1; }

int fbink_get_state(const FBInkConfig* config, FBInkState* state)
{
    (void)config;
    if (state) {
        state->fontsize_mult = 1;
        state->screen_width = 0;
        state->screen_height = 0;
    }
    return -1;
}

int fbink_cls(int fbfd, const FBInkConfig* config, const FBInkRect* rect, bool no_rota)
{
    (void)fbfd; (void)config; (void)rect; (void)no_rota;
    return -1;
}

int fbink_refresh(int fbfd, uint32_t top, uint32_t left, uint32_t width, uint32_t height,
                  const FBInkConfig* config)
{
    (void)fbfd; (void)top; (void)left; (void)width; (void)height; (void)config;
    return -1;
}

int fbink_print(int fbfd, const char* string, const FBInkConfig* config)
{
    (void)fbfd; (void)string; (void)config;
    return -1;
}

int fbink_close(int fbfd) { (void)fbfd; return -1; }
