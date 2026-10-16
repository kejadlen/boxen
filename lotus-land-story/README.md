# Lotus Land Story

```
# setup
echo 'domain = "kejadlen.dev"' > terraform.tfvars

# terraform
terraform apply

# add the IP to ~/.ssh/config

# make sure we can hit it
ansible all -m ping

# ansible
ansible-playbook -l lotus-land-story lotus-land-story/main.yml

# manually connect to tailscale

# specific playbooks
ansible-playbook -l lotus-land-story lotus-land-story/<playbook>.yml
```
