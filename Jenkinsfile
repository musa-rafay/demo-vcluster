```groovy
// Jenkinsfile: Multibranch Pipeline to spin up a vCluster on an OCI node per PR
pipeline {
agent any

environment {
// Path to vcluster CLI on the remote OCI node
VCLUSTER\_CLI = '/usr/local/bin/vcluster'
}

stages {
stage('Checkout') {
steps {
checkout scm
}
}

```
stage('Create vCluster on OCI Node') {
  when { changeRequest() }
  steps {
    // SSH into the OCI node and run vcluster commands there
    sshCommand remote: [
      name:       'oci-node',
      host:       'YOUR.OCI.NODE.IP',      
      user:       'ubuntu',
      identity:   credentials('oci-ssh-creds'),
      knownHosts: allowAnyHosts
    ],
    command: '''
      #!/bin/bash
      set -euo pipefail

      PR_ID=\$CHANGE_ID
      VNAME=pr-\$PR_ID
      NS=vcluster-\$PR_ID

      # Ensure kubeconfig on remote has cluster access
      export KUBECONFIG=~/.kube/config

      # Create the vcluster with port-forward
      ${VCLUSTER_CLI} create \$VNAME \
        -n \$NS \
        --create-namespace \
        --expose 80:80 \
        --port-forward &

      # Wait until the vcluster is ready
      until kubectl --context=\$NS get pods &>/dev/null; do
        echo "Waiting for vcluster \$VNAME to be ready..."
        sleep 5
      done

      # Deploy feature manifests
      kubectl --context=\$NS apply -f testbed/feature-a.yaml
      kubectl --context=\$NS apply -f testbed/feature-b.yaml
    '''
  }
}
```

}

post {
cleanup {
// Tear down the vcluster when the PR is closed/merged
sshCommand remote: \[
name:       'oci-node',
host:       '141.148.143.154',
user:       'ubuntu',
identity:   credentials('oci-ssh-creds'),
knownHosts: allowAnyHosts
],
command: '''
\#!/bin/bash
set -euo pipefail

```
    if [ "\$CHANGE_TARGET" = 'main' ]; then
      ${VCLUSTER_CLI} delete pr-\$CHANGE_ID -n vcluster-\$CHANGE_ID --yes
    fi
  '''
}
```

}
}
```
