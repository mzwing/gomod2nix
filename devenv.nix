{
  inputs,
  pkgs,
  ...
}: {
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

  packages =
    (with pkgs; [
      actionlint
      alejandra
      golangci-lint
      just
      nixd
      shellcheck
      shfmt
    ])
    ++ (with inputs.nur-packages.packages.${pkgs.stdenv.hostPlatform.system}; [
      typenix
    ]);

  enterTest = ''
    go version
    dlv version
    gopls version
    actionlint -version
    alejandra --version
    golangci-lint version
    just --version
    nixd --version
    shellcheck --version
    shfmt --version
    typenix --version
  '';
}
