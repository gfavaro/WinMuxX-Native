// Adapted from mikker/Dinky e05ae28f3e814bbae1cf171567be14e0dcba6548.
// See legal/native-spaces for MIT licenses and upstream attributions.
#import "skylight.h"
#import "query.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

// Mach-O walk lifted from mimi internal/native/space.m (mimi_macho_find_*), same as yabai macho_find_symbol.
void *dinky_skylight_symbol(const char *mangledName)
{
    static const char *image = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
    struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, image) == 0) {
            header = (struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!header) return NULL;

    struct segment_command_64 *linkedit = NULL;
    struct symtab_command *symtab = NULL;
    uint8_t *cursor = (uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64 && strcmp(((struct segment_command_64 *)cmd)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (struct segment_command_64 *)cmd;
        } else if (cmd->cmd == LC_SYMTAB) {
            symtab = (struct symtab_command *)cmd;
        }
        cursor += cmd->cmdsize;
    }
    if (!linkedit || !symtab) return NULL;

    uint8_t *base = (uint8_t *)(uintptr_t)(linkedit->vmaddr - linkedit->fileoff + slide);
    const char *strings = (const char *)(base + symtab->stroff);
    struct nlist_64 *symbols = (struct nlist_64 *)(base + symtab->symoff);
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if (strcmp(strings + symbols[i].n_un.n_strx, mangledName) == 0) {
            return (void *)(uintptr_t)(symbols[i].n_value + slide);
        }
    }
    return NULL;
}

int dinky_front_connection(void)
{
    ProcessSerialNumber psn = {0};
    int cid = 0;
    if (_SLPSGetFrontProcess(&psn) != noErr) return 0;
    if (SLSGetConnectionIDForPSN(dinky_connection(), &psn, &cid) != kCGErrorSuccess) return 0;
    return cid;
}
