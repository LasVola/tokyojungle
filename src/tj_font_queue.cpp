/* Lost wake-up in the game's text worker (PFontThread, NPUA80523 v01.00).
 *
 * Map labels, the legend and other UI strings are drawn by a worker thread.
 * Its object (r30 in func_001C0540) holds:
 *   +0x000  six request states (0 free, 1 queued, 2 drawing)
 *   +0x018  six 0x138-byte requests
 *   +0x790  busy flag
 *   +0x794  event flag id
 * The producer (func_001C067C) queues a request and only signals the event
 * flag when busy == 0. The worker scans the six slots, then sets busy = 0 and
 * sleeps. A request queued after its slot was scanned but before busy = 0 is
 * never signalled, so its label keeps the old text from a previous screen
 * (the map showed legend words such as "Lair" or "Female" where area names
 * belong) or stays blank. On the PS3 that window is tiny; on PC threads it
 * is wide enough to hit almost every time the map opens.
 *
 * scripts/post_lift.py inserts a call right after the worker sets busy = 0.
 * If a request is still queued, the worker sets busy = 1 again and goes back
 * to drawing instead of sleeping. Logs "[tj-font] ..." the first few times.
 */
#include "recomp_bridge.h"

#include <windows.h>

int tj_font_requests_pending(uint32_t obj)
{
    /* Order the worker's busy = 0 store before these loads (the producer
     * stores the state first, then reads busy). */
    MemoryBarrier();
    for (uint32_t i = 0; i < 6; i++) {
        if (vm_read32(obj + i * 4) == 1) {
            static volatile LONG logged;
            if (InterlockedIncrement(&logged) <= 8)
                fprintf(stderr, "[tj-font] slot %u queued while worker went idle: drawing it now\n", i);
            return 1;
        }
    }
    return 0;
}
