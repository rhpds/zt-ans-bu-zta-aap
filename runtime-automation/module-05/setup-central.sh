#!/bin/bash
 ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags remove_section -e aap_remove_section=4
 ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/configure-aap-project.yml --tags section5,rbac
## ansible-playbook -i /tmp/zta-workshop-aap/inventory/hosts.ini /tmp/zta-workshop-aap/setup/deploy-splunk.yml --skip-tags eda_webhook
