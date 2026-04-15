#!/bin/bash
 ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags remove_section -e aap_remove_section=1
 ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags section2,rbac
