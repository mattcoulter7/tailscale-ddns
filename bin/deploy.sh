docker build -f Dockerfile -t entrypoint:latest .
docker login
docker tag entrypoint:latest mattcoulter7/entrypoint:latest
docker push mattcoulter7/entrypoint:latest
