pipeline {
  agent any

  environment {
    SSH_CREDS = 'oci-node'
    OCI_HOST  = '144.24.36.64'
    KCFG_FILE = 'kubeconfig.yaml'
    SVCS      = ''
  }

  stages {
    stage('Detect changes') {
      steps {
        script {
          def target = env.CHANGE_TARGET ?: 'main'
          sh "git fetch --no-tags --quiet origin ${target}:${target}"

          def raw = sh(
            script: "git diff --name-only origin/${target}...HEAD || true",
            returnStdout: true
          ).trim()

          def features = []
          raw.split('\\r?\\n').each { path ->
            if (path.startsWith('scripts/testbed/') && path.endsWith('.yaml')) {
              def base = path.tokenize('/')[-1]
              features << base.replaceAll(/\\.yaml\$/, '')
            }
          }

          if (features) {
            env.SVCS = features.join(',')
            echo "Services to patch/test: ${env.SVCS}"
          } else {
            env.SVCS = ''
            echo '⚠️  No feature manifests changed; continuing (nothing to deploy).'
          }
        }
      }
    }

    stage('Provision vcluster') {
      when { changeRequest() }
      steps {
        withCredentials([ sshUserPrivateKey(credentialsId: env.SSH_CREDS,
                                            keyFileVariable: 'KEY',
                                            usernameVariable: 'SSHUSER') ]) {
          sh """
            set -e
            echo "[INFO] Provisioning vcluster for PR ${CHANGE_ID} on ${OCI_HOST}"
            scp -i \$KEY -o StrictHostKeyChecking=no scripts/create-vcluster-v2.sh \$SSHUSER@${OCI_HOST}:/tmp/create.sh
            ssh -i \$KEY -o StrictHostKeyChecking=no \$SSHUSER@${OCI_HOST} 'bash /tmp/create.sh ${CHANGE_ID}'
            scp -i \$KEY -o StrictHostKeyChecking=no \$SSHUSER@${OCI_HOST}:~/vcluster/kubeconfig-${CHANGE_ID}.yaml ${KCFG_FILE}
            chmod 600 ${KCFG_FILE}
          """
        }
      }
    }

    stage('Deploy changed') {
      when { expression { return env.SVCS?.trim() } }
      steps {
        sh """
          if [ ! -f "${KCFG_FILE}" ]; then
            echo "[ERROR] kubeconfig not found; aborting deploy."
            exit 1
          fi
          export KUBECONFIG=${KCFG_FILE}
          ci/deploy_changed.sh kubernetes-admin@kubernetes "${SVCS}"
        """
      }
    }

    stage('Run tests') {
      when { expression { return env.SVCS?.trim() } }
      steps {
        sh """
          if [ ! -f "${KCFG_FILE}" ]; then
            echo "[ERROR] kubeconfig not found; aborting tests."
            exit 1
          fi
          export KUBECONFIG=${KCFG_FILE}
          ci/run_tests.sh "${SVCS}"
        """
      }
    }
  }

  post {
    always {
      script {
        if (env.CHANGE_ID) {
          echo "PR ${env.CHANGE_ID}: vcluster retained. Remember to clean up later."
        } else {
          echo "No PR context."
        }
      }
    }
  }
}

