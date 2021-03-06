/* common.c  -  Common functions */

/* Written 1993 by Werner Almesberger */

/* FAT32, VFAT, Atari format support, and various fixes additions May 1998
 * by Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de> */


#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>

#include "common.h"
#include "dosfsck.h" /* verbose */


typedef struct _link {
    void *data;
    int size; /* for stats, 2.11b */
    struct _link *next;
} LINK;

static int usedBytes = 0;
static int maxBytes = 0;
static int usedBlocks = 0;
static int maxBlocks = 0;

void showalloc(void) {
    if (!verbose) return;
    fprintf(stderr, "Heap usage: %d bytes in %d blocks, peak: %d bytes, %d blocks\n",
        usedBytes, usedBlocks, maxBytes, maxBlocks);
}

void die(char *msg,...)
{
    va_list args;

    va_start(args,msg);
    vfprintf(stderr,msg,args);
    va_end(args);
    fprintf(stderr,"\n");
    showalloc();
    exit(1);
}


void pdie(char *msg,...)
{
    va_list args;

    va_start(args,msg);
    vfprintf(stderr,msg,args);
    va_end(args);
    die(": %s\nAborting.",
	(errno) ? strerror(errno) : "general problems");
}


void *alloc(int size)
{
    void *this;

    this = malloc(size);
    if (this) {
        usedBytes += size;
        if (usedBytes>maxBytes) maxBytes=usedBytes;
        usedBlocks++;
        if (usedBlocks>maxBlocks) maxBlocks=usedBlocks;
        return this;
    }
    pdie("malloc: failed to alloc %d bytes (used: %d in %d blocks)",
        size, usedBytes, usedBlocks);
    return NULL; /* for GCC */
}


void *qalloc(void **root,int size)
{
    LINK *link;

    link = alloc(sizeof(LINK));
    link->next = *root;
    link->size = size; /* 2.11b */
    *root = link;
    return link->data = alloc(size);
}


void qfree(void **root)
{
    LINK *this;

    while (*root) {
	this = (LINK *) *root;
	*root = this->next;
	myfree(this->data, this->size);
	myfree(this, sizeof(LINK));
    }
}

void myfree(void *what, int size)
{
    usedBytes -= size;
    usedBlocks--;
    free(what);
}


int min(int a,int b)
{
    return a < b ? a : b;
}


char get_key(char *valid,char *prompt)
{
    int ch,okay;

    while (1) {
	if (prompt) printf("%s ",prompt);
	fflush(stdout);
	while (ch = getchar(), ch == ' ' || ch == '\t');
	if (ch == EOF) exit(1);
	if (!strchr(valid,okay = ch)) okay = 0;
	while (ch = getchar(), ch != '\n' && ch != EOF);
	if (ch == EOF) exit(1);
	if (okay) return okay;
	printf("Invalid input.\n");
    }
}

/* Local Variables: */
/* tab-width: 8     */
/* End:             */
