FROM nixpkgs/nix-flakes

RUN echo "substituters = https://cache.nixos.org https://pub-aa815f1da11442fd9edb92952602bf56.r2.dev https://nix-postgres-artifacts.s3.amazonaws.com" >> /etc/nix/nix.conf

RUN echo "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nuvix-cache:xgUMoDBFKzRx3murcFhpx607tZ6AnFgdb85FuFxmUFE= nix-postgres-artifacts:dGZlQOvKcNEjvT7QEAJbcV6b6uk7VF/hWMjhYleiaLI=" >> /etc/nix/nix.conf


USER $USER

RUN mkdir -p /workspace

COPY ./ /workspace

RUN chmod +x /workspace/docker/nix/build_nix.sh

RUN chown -R $USER:$USER /workspace
