cd /opt/babelfish-image
sudo podman build -t localhost/babelfish:5.4.0-pg17.7 \
    --build-arg BABEL_TAG=BABEL_5_4_0__PG_17_7 \
    -f Containerfile .
