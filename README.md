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
$ bundle exec rake test
```

If `bundle install` fails, try running `bundle config set --global path '~/.gem'`.

- To use direct connection to `libvirt` (recommended), install the libvirt Ruby gem: `sudo apt install ruby-libvirt`
- To use lazyvirt over `virsh` binary, run `sudo apt install libvirt-clients`
- To give your user control over virtual machines, add your user to `libvirt` group:
  `sudo usermod -aG libvirt $USER` and log out/log in.
- To setup VMs, install `sudo apt install virt-manager`

## Running

```
bin/lazyvirt
```

## Enabling Ballooning

Without ballooning properly enabled in your guest OS, lazyvirt can't control the amount of memory
available to the guest OS. To enable ballooning:

- Make sure your VM libvirt xml file contains the `<memballoon>` device
- Guest agent is installed and running:
  - Linux: `sudo apt install qemu-guest-agent`; `systemctl status qemu-guest-agent` shows that the service is running.
  - Windows: Download and install `virtio-win-guest-tools.exe` from [windows virtio repo](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/?C=M;O=D).
- Most modern Linux distros have the `virtio_balloon` kernel module baked in, and so `modprobe virtio_balloon` isn't necessary.

If the memory data isn't updated:

- Either make sure your VM libvirt xml `<memballoon>` device contains the `<stats period='5' /> ` child element, OR
- in the Virtual Machine Manager (`sudo apt install virt-manager`) preferences, polling, make sure "Poll Memory stats" is checked.

More info at [VirtIO Memory Ballooning](https://pmhahn.github.io/virtio-balloon/).

# Developing

Run tests via:
```
$ bundle exec rake test
```

# Future plans

- Automatic balloon control (needs to be enabled)
- Add [libvirt](https://ruby.libvirt.org/) client
- Add dummy virt client
- disk usage

