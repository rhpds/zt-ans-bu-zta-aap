#!/bin/bash
ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags remove_section -e aap_remove_section=2
ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags section3,rbac
ipa group-remove-member team-infrastructure --users=neteng
ipa group-add team-readonly --desc="Read-only template visibility (all workshop users)"
ipa group-add-member team-readonly --users=neteng
