# The screenshot browser: Playwright's image with the playwright module installed. Lab
# equipment, built while connected (demo/shoot.sh builds it on the host network), because on
# the site network npm has nothing to install from: playwright is not part of the AI stack.
FROM mcr.microsoft.com/playwright:v1.49.1-noble@sha256:ad57c625d284e8d287abcd40d18434582b2e354de71c8428cb080112b0c45960
WORKDIR /opt/shoot
RUN npm i --silent --no-fund --no-audit playwright@1.49.1
