{
  inputs,
  pkgs,
  ...
}: {
  overlays = [inputs.nur.overlays.default];

  languages.go = {
    enable = true;
    enableHardeningWorkaround = true;
    delve.enable = true;
    lsp.enable = true;
  };

  languages.nix = {
    enable = true;
    lsp.enable = true;
  };

  packages = with pkgs; [
    alejandra
    golangci-lint
    nixd
    nur.repos.mzwing.typenix
  ];

  enterTest = ''
    go version
    dlv version
    gopls version
    alejandra --version
    golangci-lint version
    nixd --version
    typenix --version
  '';
}
