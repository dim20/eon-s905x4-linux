# `scripts/overrides/` — what the image build substitutes for the vendor's

The image is built from the vendor's rootfs, which is full of the vendor's
own idea of what a login looks like and which units should run. This
directory is what replaces it. `scripts/build-stick-image.sh` applies it to
a copy of the tree, so a rebuilt image gets these automatically and nothing
is hand-edited on a box.

## How each name is applied

| name | goes to |
|---|---|
| `etc/` | the files in it are copied to `/etc/` (the vendor's symlinks are removed first) |
| `motd/` | `/etc/update-motd.d/`, mode 0755 |
| `<name>.service.d/` | a drop-in at `/etc/systemd/system/<name>.service.d/` |
| `<name>` (a file) | a unit at `/etc/systemd/system/<name>` |

## The trap: `/etc/issue` is not plain text

`getty` expands backslash escapes in `/etc/issue`, and it **silently eats
the backslash** of anything it does not recognise. The wordmark's art is
made of backslashes, so the first version rendered like this on the
television:

```
 | ____| / __  |  | | |      <- the backslash is gone
```

The fix is to double them — `\\` prints one backslash — while leaving the
escapes that are *meant* to work alone:

| in the file | prints |
|---|---|
| `\\` | `\` — a literal backslash |
| `\S` | the kernel name (`Linux`) |
| `\r` | the kernel release |
| `\m` | the machine architecture |
| `\n` | the hostname |
| `\4` | the IPv4 address |
| `\l` | the terminal name (`tty1`, `ttyS0`) |

`\l` is the answer to "which terminal am I on": the box has several, and the
login prompt looks identical on all of them.

**`/etc/issue.net` is different.** `sshd` prints it as its `Banner`, by
copying the bytes, so no escapes are expanded and no doubling is needed.
That is why the two files are not the same text.
