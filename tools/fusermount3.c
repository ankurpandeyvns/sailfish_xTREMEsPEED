#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <fcntl.h>

/* Strip problematic options that old kernels dont support */
static void clean_opts(const char *in, char *out, int outlen) {
    char *buf = strdup(in);
    char *tok = strtok(buf, ",");
    out[0] = 0;
    while (tok) {
        /* Skip subtype and fsname - old FUSE kernels may reject them */
        if (strncmp(tok, "subtype=", 8) != 0 && strncmp(tok, "fsname=", 7) != 0) {
            if (out[0]) strncat(out, ",", outlen - strlen(out) - 1);
            strncat(out, tok, outlen - strlen(out) - 1);
        }
        tok = strtok(NULL, ",");
    }
    free(buf);
}

int main(int argc, char *argv[]) {
    int unmount = 0;
    char *opts = NULL;
    char *mountpoint = NULL;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-u") == 0) { unmount = 1; continue; }
        if (strcmp(argv[i], "-o") == 0 && i+1 < argc) { opts = argv[++i]; continue; }
        if (strcmp(argv[i], "--") == 0) { if (i+1 < argc) mountpoint = argv[i+1]; break; }
        if (argv[i][0] != '-') { mountpoint = argv[i]; break; }
    }

    if (unmount && mountpoint)
        return umount2(mountpoint, 0) ? 1 : 0;

    if (!mountpoint) return 1;

    char *commfd_str = getenv("_FUSE_COMMFD");
    if (!commfd_str) return 1;
    int commfd = atoi(commfd_str);

    int fd = open("/dev/fuse", O_RDWR);
    if (fd < 0) { perror("open /dev/fuse"); return 1; }

    /* Build clean mount options */
    char clean[4096];
    if (opts) clean_opts(opts, clean, sizeof(clean)); else clean[0] = 0;

    char mount_opts[4096];
    if (clean[0])
        snprintf(mount_opts, sizeof(mount_opts),
            "fd=%d,rootmode=40000,user_id=0,group_id=0,%s", fd, clean);
    else
        snprintf(mount_opts, sizeof(mount_opts),
            "fd=%d,rootmode=40000,user_id=0,group_id=0", fd);

    fprintf(stderr, "fusermount3: opts=[%s]\n", mount_opts);

    /* Try mount with different flags */
    int rc;
    /* Attempt 1: standard */
    rc = mount("rclone", mountpoint, "fuse", MS_NOSUID|MS_NODEV, mount_opts);
    if (rc != 0) {
        fprintf(stderr, "fusermount3: attempt1 errno=%d (%s)\n", errno, strerror(errno));
        /* Attempt 2: minimal flags */
        rc = mount("rclone", mountpoint, "fuse", 0, mount_opts);
    }
    if (rc != 0) {
        fprintf(stderr, "fusermount3: attempt2 errno=%d (%s)\n", errno, strerror(errno));
        /* Attempt 3: only fd and rootmode */
        char minimal[256];
        snprintf(minimal, sizeof(minimal), "fd=%d,rootmode=40000,user_id=0,group_id=0", fd);
        rc = mount("rclone", mountpoint, "fuse", MS_NOSUID|MS_NODEV, minimal);
    }
    if (rc != 0) {
        fprintf(stderr, "fusermount3: attempt3 errno=%d (%s)\n", errno, strerror(errno));
        close(fd);
        return 1;
    }

    /* Send fd back via _FUSE_COMMFD */
    struct msghdr msg = {0};
    struct iovec iov;
    char buf = 0;
    iov.iov_base = &buf;
    iov.iov_len = 1;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    memset(cmsgbuf, 0, sizeof(cmsgbuf));
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
    if (sendmsg(commfd, &msg, 0) < 0) {
        perror("fusermount3: sendmsg");
        umount2(mountpoint, MNT_DETACH);
        close(fd);
        return 1;
    }
    fprintf(stderr, "fusermount3: OK fd=%d\n", fd);
    return 0;
}
