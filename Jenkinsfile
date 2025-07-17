pipeline {
  agent any
  parameters {
    booleanParam(name: 'RUN_AGAIN', defaultValue: false,
                 description: 'Re‑run tests without a new approval')
  }
  environment {
    SSH_CREDS = 'oci-node'
    OCI_HOST  = '144.24.36.64'
    KCFG_FILE = 'kubeconfig.yaml'
    SVCS      = ''          // will be filled in Detect‑changes
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
          /** find changed manifests */
          def changed = sh(
            script: '''
              git fetch origin main --quiet
              git diff --name-only origin/main...HEAD |
                grep '^scripts/testbed/' |
                sed -E 's#scripts/testbed/(feature-[^.]+)\\.yaml#\\1#' |
                sort -u | paste -sd "," -
            ''',
            returnStdout: true
          ).trim()

          if (!changed) {
            echo '⚠️  No feature manifests changed; nothing to deploy.'
            // uncomment the next line if you really want to abort
            // error 'Aborting build.'
          }

          env.SVCS = changed                              // <- make it visible later
          echo "Services to patch/test: ${env.SVCS}"
        }
      }
    }

    /** Create vcluster for PRs; reuse existing kubeconfig on main */
    stage('Provision vcluster') {
      when { changeRequest() }                           // only for PR builds
      steps {
        withCredentials([ sshUserPrivateKey(credentialsId: env.SSH_CREDS,
                                            keyFileVariable: 'KEY') ]) {
          sh """
            scp -i \$KEY -o StrictHostKeyChecking=no \
                scripts/create-vcluster-v2.sh ubuntu@${OCI_HOST}:/tmp/create.sh
            ssh -i \$KEY -o StrictHostKeyChecking=no \
                ubuntu@${OCI_HOST} 'bash /tmp/create.sh ${CHANGE_ID}'
            scp -i \$KEY -o StrictHostKeyChecking=no \
                ubuntu@${OCI_HOST}:~/vcluster/kubeconfig-${CHANGE_ID}.yaml \
                ${env.KCFG_FILE}
          """
        }
      }
    }

    stage('Deploy changed') {
      when { expression { env.SVCS } }                   // skip if list empty
      steps {
        sh """
          export KUBECONFIG=${env.KCFG_FILE}
          ci/deploy_changed.sh kubernetes-admin@kubernetes "${env.SVCS}"
        """
      }
    }

    stage('Run tests') {
      when { expression { env.SVCS } }
      steps {
        sh """
          export KUBECONFIG=${env.KCFG_FILE}
          ci/run_tests.sh "${env.SVCS}"
        """
      }
    }
  } // stages

  post {
    always {
      // intentionally NOT deleting vcluster; leaving up for manual inspection
      script {
        if (env.CHANGE_ID) {
          echo "PR ${env.CHANGE_ID}: vcluster retained. Remember to clean it up later."
        } else {
          echo 'No PR context – nothing to clean up.'
        }
      }
      // cleanWs() removed so kubeconfig + logs remain in workspace archive
    }
  }
}
