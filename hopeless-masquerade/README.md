# hopeless-masquerade

A Raspberry Pi 4 Model B running [BirdNET-Pi][birdnet-pi].

## setup

```sh
ansible-playbook -l hopeless-masquerade -e ansible_host=ANSIBLE_HOST --ask-become-pass hopeless-masquerade/main.yml

curl -s https://raw.githubusercontent.com/zach7036/BirdNET-Pi-Enhanced-Version/main/newinstaller.sh | bash
```

Then apply tofu, which tags the device `tag:birdnet` and limits what it
can reach on the tailnet. Reboot so the kernel picks up `cmdline.txt`
changes.

[birdnet-pi]: https://github.com/zach7036/BirdNET-Pi
