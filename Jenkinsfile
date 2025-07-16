pipeline {
  agent any
  environment {
    VCLUSTER_CLI='/usr/local/bin/vcluster'
  }
  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }
    stage('Create vCluster') {
      when { changeRequest() }
      steps {
        script {
          def remote = [
            name: 'oci-node',
            host: '141.148.143.154',
            user: 'ubuntu',
            identity: credentials('oci-ssh-creds'),
            allowAnyHosts: true
          ]
          sshCommand remote: remote, command: '''
set -euo pipefail
PR_ID=$CHANGE_ID
VNAME=pr-$PR_ID
NS=vcluster-$PR_ID
export KUBECONFIG=~/.kube/config
${VCLUSTER_CLI} create $VNAME -n $NS --create-namespace --expose 80:80 --port-forward &
until kubectl --context=$NS get pods &>/dev/null; do sleep 5; done
kubectl --context=$NS apply -f testbed/feature-a.yaml
kubectl --context=$NS apply -f testbed/feature-b.yaml
'''
        }
      }
    }
  }
  post {
    cleanup {
      script {
        def remote = [
          name: 'oci-node',
          host: '141.148.143.154',
          user: 'ubuntu',
          identity: credentials('oci-ssh-creds'),
          allowAnyHosts: true
        ]
        sshCommand remote: remote, command: '''
set -euo pipefail
if [ "$CHANGE_TARGET" = 'main' ]; then
  ${VCLUSTER_CLI} delete pr-$CHANGE_ID -n vcluster-$CHANGE_ID --yes
fi
'''
      }
    }
  }
}
