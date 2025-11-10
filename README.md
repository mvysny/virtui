# LazyVirt

A TUI client for libvirt/virsh. Under development. Requires Ruby 3.3+. Currently runs `virsh`.
Currently only tested on Linux host: probably won't work on Windows nor MacOS.

## Setup

Install Ruby:
```bash
$ sudo apt install ruby ruby-bundler
```

Run these commands in this project folder, to install project dependencies:
```
$ bundle install
```

If `bundle install` fails, try running `bundle config set --global path '~/.gem'`.

- To use lazyvirt over `virsh` binary, run `sudo apt install libvirt-clients` (recommended)
- To use direct connection to `libvirt` (experimental, broken at the moment), install the libvirt Ruby gem: `sudo apt install ruby-libvirt`
- To give your user control over virtual machines, add your user to `libvirt` group:
  `sudo usermod -aG libvirt $USER` and log out/log in.
- To setup VMs, install `sudo apt install virt-manager`

## Running

```
bin/lazyvirt
```

# Ballooning

"Balloon" is closely related to precise control and statistics of guest memory. When ballooning is enabled, you can see
how much memory the guest OS is using for programs, disk cache, and how much is free. There's more: you can also control
the amount of memory the guest OS can use, *while the guest OS is running*. So, if your guest OS isn't using much memory at the moment,
you can shrink its memory, decreasing the memory footprint of the VM on host and giving host back a bit of memory.

This is done by a 'balloon' program running on guest: it can 'inflate' itself by increasing its memory usage the guest OS.
Host hypervisor knows that 'balloon'-occupied memory is unused by the guest OS, and therefore free to use by the host OS.

When guest needs more memory, the balloon 'deflates': the 'balloon' program releases its memory. The VM starts using more memory on host OS,
but this gives the guest OS more memory to work with.

You can inflate and deflate the balloon as many times as you need. By default the balloon inflating and deflating is manual work:
you run `virsh setmem` to control the balloon size. However, lazyvirt can do this automatically for you.

## Enabling Ballooning

Without ballooning properly enabled in your guest OS, lazyvirt can't control the amount of memory
available to the guest OS. To enable ballooning:

- Make sure your VM libvirt xml file contains the `<memballoon>` device (it does by default when you create VMs via `virt-manager`)
- Guest QEMU agent is installed and running:
  - Linux: `sudo apt install qemu-guest-agent`; `systemctl status qemu-guest-agent` shows that the service is running.
  - Linux: `virtio_balloon` kernel module must be activated. Most modern Linux distros have the `virtio_balloon` kernel module baked in: it's not shown in `lsmod`,
    but it's always active so `modprobe virtio_balloon` isn't necessary.
  - Windows: Download and install `virtio-win-guest-tools.exe` from [windows virtio repo](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/?C=M;O=D).

If the memory data doesn't seem to be updated in lazyvirt:

- Either make sure your VM libvirt xml `<memballoon>` device contains the `<stats period='5' /> ` child element, OR
- in the Virtual Machine Manager (`sudo apt install virt-manager`) preferences, polling, make sure "Poll Memory stats" is checked.

When ballooning is enabled properly in a VM, 🎈 is shown next to the VM name in lazyvirt.

More info at [VirtIO Memory Ballooning](https://pmhahn.github.io/virtio-balloon/).

## Automatic Balloon inflate/deflate

TODO not yet implemented.

# Developing

Run tests via:
```
$ bundle exec rake test
```

# Future plans

- Automatic balloon control (needs to be enabled)
- Add [libvirt](https://ruby.libvirt.org/) client: blocked by [bug #14](https://gitlab.com/libvirt/libvirt-ruby/-/issues/14)
- Add dummy virt client
- detect obsolete memory data (when the mem stats aren't refreshed by `<memballoon>` or `virt-manager`, and display a 'turtle' next to the VM name

