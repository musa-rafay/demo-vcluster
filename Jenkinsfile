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
          // Fetch the target branch into a local ref named "base_target"
          sh "git fetch --no-tags --quiet origin ${target}:base_target"
        
          // Use merge-base to find a common ancestor (robust for shallow refs)
          def base = sh(
            script: "git merge-base HEAD base_target || echo base_target",
            returnStdout: true
          ).trim()
        
          def raw = sh(
            script: "git diff --name-only ${base}...HEAD || true",
            returnStdout: true
          ).trim()
        
          def features = []
          raw.split('\\r?\\n').each { path ->
            if (path.startsWith('scripts/testbed/') && path.endsWith('.yaml')) {
              def baseName = path.tokenize('/')[-1]
              features << baseName.replaceAll(/\\.yaml\$/, '')
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
        sshagent(credentials: [env.SSH_CREDS]) {
          sh """
            set -e
            echo "[INFO] Provisioning vcluster for PR ${CHANGE_ID} on ${OCI_HOST}"
            scp -o StrictHostKeyChecking=no scripts/create-vcluster-v2.sh ubuntu@${OCI_HOST}:/tmp/create.sh
            ssh -o StrictHostKeyChecking=no ubuntu@${OCI_HOST} 'bash /tmp/create.sh ${CHANGE_ID} 5 1.32 kubernetes-admin@kubernetes'
            scp -o StrictHostKeyChecking=no ubuntu@${OCI_HOST}:~/vc-kcfg/kubeconfig-${CHANGE_ID}.yaml ${KCFG_FILE}
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
