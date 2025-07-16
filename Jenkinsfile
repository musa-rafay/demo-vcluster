pipeline {
  agent any
  parameters {
    booleanParam(name: 'RUN_AGAIN', defaultValue: false, description: 'Re‑run tests without a new approval')
  }
  environment {
    SSH_CREDS = 'oci-ssh-creds'
    OCI_HOST  = '141.148.143.154'
    KCFG_FILE = 'kubeconfig.yaml'
  }
  stages {

    stage('Skip if last run green') {
      when { expression { !params.RUN_AGAIN } }
      steps {
        script {
          def prev = currentBuild.rawBuild.getPreviousBuild()
          if (prev && prev.result == 'SUCCESS') {
            currentBuild.result = 'SUCCESS'
            echo 'Previous build green → skipping.'
          }
        }
      }
    }

   stage('Detect changes') {
    steps {
      script {
        // Returns "feature-a,feature-b" (comma‑separated) or empty string
        CHANGED_SERVICES = sh(
          script: '''
            git fetch origin main --quiet
            git diff --name-only origin/main...HEAD \
              | grep '^scripts/testbed/' \
              | sed -E 's#scripts/testbed/(feature-[^.]+)\\.yaml#\\1#' \
              | sort -u | paste -sd "," -
          ''',
          returnStdout: true
        ).trim()
        if (!CHANGED_SERVICES) {
          error 'No changes detected under scripts/testbed — aborting build'
        }
        echo "Services to patch/test: ${CHANGED_SERVICES}"
      }
    }
  }

    stage('Provision vcluster') {
      when { changeRequest() }
      steps {
        withCredentials([sshUserPrivateKey(credentialsId: env.SSH_CREDS, keyFileVariable: 'KEY')]) {
          sh """
            scp -i \$KEY -o StrictHostKeyChecking=no scripts/create-vcluster-v2.sh ubuntu@${OCI_HOST}:/tmp/create.sh
            ssh -i \$KEY -o StrictHostKeyChecking=no ubuntu@${OCI_HOST} 'bash /tmp/create.sh ${CHANGE_ID}'
            scp -i \$KEY -o StrictHostKeyChecking=no ubuntu@${OCI_HOST}:~/vcluster/kubeconfig-${CHANGE_ID}.yaml ${env.KCFG_FILE}
          """
        }
      }
    }

    stage('Deploy changed') {
      steps {
        sh """
          export KUBECONFIG=${env.KCFG_FILE}
          ci/deploy_changed.sh kubernetes-admin@kubernetes "$SVCS"
        """
      }
    }

    stage('Run tests') {
      steps {
        sh """
          export KUBECONFIG=${env.KCFG_FILE}
          ci/run_tests.sh "$SVCS"
        """
      }
    }
  }

  post {
    always {
      withCredentials([sshUserPrivateKey(credentialsId: env.SSH_CREDS, keyFileVariable: 'KEY')]) {
        sh """
          ssh -i \$KEY -o StrictHostKeyChecking=no ubuntu@${OCI_HOST} 'vcluster delete vcluster-${CHANGE_ID} -n dev-${CHANGE_ID} --yes || true'
        """
      }
    }
  }
}

