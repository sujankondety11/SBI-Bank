pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        AWS_DEFAULT_REGION = 'ap-south-1'
        ECR_REGISTRY       = '298536392649.dkr.ecr.ap-south-1.amazonaws.com'
        ECR_REPOSITORY     = 'securebank-app'
        IMAGE_NAME         = 'securebank-app'
        EKS_CLUSTER        = 'securebank-eks'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: '*/main']],
                    userRemoteConfigs: [[
                        url: 'https://github.com/sujankondety11/SBI-Bank.git',
                        credentialsId: 'github-cred'
                    ]]
                ])
            }
        }

        stage('Install Dependencies') {
            steps {
                sh '''
                    docker run --rm \
                    --volumes-from jenkins \
                    -w "$WORKSPACE" \
                    node:20-alpine \
                    npm ci
                '''
            }
        }

        stage('Run Tests') {
            steps {
                sh '''
                    docker run --rm \
                    --volumes-from jenkins \
                    -w "$WORKSPACE" \
                    node:20-alpine \
                    npm test
                '''
            }
        }

        stage('OWASP Dependency Check') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'nvd-api-key',
                        variable: 'NVD_API_KEY'
                    )
                ]) {
                    sh '''
                        rm -rf dependency-check-report
                        mkdir -p dependency-check-report

                        docker run --rm \
                        --user root \
                        --volumes-from jenkins \
                        -v dependency-check-data:/usr/share/dependency-check/data \
                        -w "$WORKSPACE" \
                        owasp/dependency-check:latest \
                        --project SecureBank \
                        --scan package.json \
                        --scan package-lock.json \
                        --format HTML \
                        --nvdApiKey "$NVD_API_KEY" \
                        --out dependency-check-report
                    '''
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'dependency-check-report/**',
                        allowEmptyArchive: true,
                        fingerprint: true
                    )
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    docker build \
                    -t ${IMAGE_NAME}:${BUILD_NUMBER} \
                    -t ${IMAGE_NAME}:latest .
                '''
            }
        }

        stage('Trivy Container Scan') {
            steps {
                sh '''
                    docker run --rm \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    aquasec/trivy:latest \
                    image \
                    --scanners vuln \
                    --severity HIGH,CRITICAL \
                    ${IMAGE_NAME}:${BUILD_NUMBER}
                '''
            }
        }

        stage('Push Image to ECR') {
            steps {
                withCredentials([
                    [
                        $class: 'AmazonWebServicesCredentialsBinding',
                        credentialsId: 'aws_creds'
                    ]
                ]) {
                    sh '''
                        docker run --rm \
                        -e AWS_ACCESS_KEY_ID \
                        -e AWS_SECRET_ACCESS_KEY \
                        -e AWS_SESSION_TOKEN \
                        -e AWS_DEFAULT_REGION \
                        public.ecr.aws/aws-cli/aws-cli:latest \
                        ecr get-login-password \
                        --region "$AWS_DEFAULT_REGION" |
                        docker login \
                        --username AWS \
                        --password-stdin "$ECR_REGISTRY"

                        docker tag \
                        ${IMAGE_NAME}:${BUILD_NUMBER} \
                        ${ECR_REGISTRY}/${ECR_REPOSITORY}:${BUILD_NUMBER}

                        docker tag \
                        ${IMAGE_NAME}:${BUILD_NUMBER} \
                        ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest

                        docker push \
                        ${ECR_REGISTRY}/${ECR_REPOSITORY}:${BUILD_NUMBER}

                        docker push \
                        ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
                    '''
                }
            }
        }

        stage('Deploy to EKS') {
            steps {
                withCredentials([
                    [
                        $class: 'AmazonWebServicesCredentialsBinding',
                        credentialsId: 'aws_creds'
                    ]
                ]) {
                    sh '''
                        mkdir -p "$WORKSPACE/.kube"

                        # Create kubeconfig for EKS
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e AWS_ACCESS_KEY_ID \
                        -e AWS_SECRET_ACCESS_KEY \
                        -e AWS_SESSION_TOKEN \
                        -e AWS_DEFAULT_REGION \
                        public.ecr.aws/aws-cli/aws-cli:latest \
                        eks update-kubeconfig \
                        --region "$AWS_DEFAULT_REGION" \
                        --name "$EKS_CLUSTER" \
                        --kubeconfig "$WORKSPACE/.kube/config"

                        # Allow kubectl container to read kubeconfig
                        chmod 644 "$WORKSPACE/.kube/config"

                        # Generate temporary EKS authentication token
                        set +x

                        EKS_TOKEN=$(docker run --rm \
                            -e AWS_ACCESS_KEY_ID \
                            -e AWS_SECRET_ACCESS_KEY \
                            -e AWS_SESSION_TOKEN \
                            -e AWS_DEFAULT_REGION \
                            public.ecr.aws/aws-cli/aws-cli:latest \
                            eks get-token \
                            --region "$AWS_DEFAULT_REGION" \
                            --cluster-name "$EKS_CLUSTER" \
                            --query 'status.token' \
                            --output text)

                        export EKS_TOKEN

                        # Deploy PostgreSQL
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        apply -f k8s/postgres.yaml

                        # Wait for PostgreSQL
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        rollout status deployment/postgres \
                        -n securebank \
                        --timeout=180s

                        # Deploy SecureBank
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        apply -f k8s/app.yaml

                        # Use the exact image from this Jenkins build
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        set image deployment/securebank-app \
                        securebank-app="$ECR_REGISTRY/$ECR_REPOSITORY:$BUILD_NUMBER" \
                        -n securebank

                        # Wait for SecureBank rollout
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        rollout status deployment/securebank-app \
                        -n securebank \
                        --timeout=300s

                        # Show application pods
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        get pods \
                        -n securebank

                        # Show application LoadBalancer
                        docker run --rm \
                        --volumes-from jenkins \
                        -w "$WORKSPACE" \
                        -e KUBECONFIG="$WORKSPACE/.kube/config" \
                        -e EKS_TOKEN \
                        bitnami/kubectl:latest \
                        --token "$EKS_TOKEN" \
                        get service securebank-app \
                        -n securebank
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker image prune -f || true
            '''
        }

        success {
            echo 'SecureBank CI/CD pipeline completed successfully.'
        }

        failure {
            echo 'SecureBank CI/CD pipeline failed.'
        }
    }
}
