{ system, nixops }:

with import <nixos/lib/testing.nix> { inherit system; };
with pkgs.lib;

makeTest ({ pkgs, ... }:

let

  # Physical NixOps model.
  physical = pkgs.writeText "physical.nix"
    ''
      rec {
        network.description = "Testing";

        target1 =
          { # Ugly - this reproduces the build-vms.nix config.
            require =
              [ <nixos/modules/virtualisation/qemu-vm.nix>
                <nixos/modules/testing/test-instrumentation.nix>
              ];
            deployment.targetEnv = "none";
            services.nixosManual.enable = false;
            boot.loader.grub.enable = false;
            # Should NixOps fill in extraHosts for the "none" backend?
            networking.extraHosts = "192.168.1.3 target2\n";
          };

        target2 = target1;
      }
    '';

  # Logical NixOps model.
  logical = n: pkgs.writeText "logical-${toString n}.nix"
    ''
      { network.description = "Testing";

        target1 =
          { config, pkgs, ... }:
          { services.openssh.enable = true;
            users.extraUsers.root.openssh.authorizedKeys.keyFiles = [ ./id_test.pub ];
            ${optionalString (n == 1) ''
              environment.systemPackages = [ pkgs.vim ];
            ''}
            ${optionalString (n == 2 || n == 3) ''
              services.httpd.enable = true;
              services.httpd.adminAddr = "e.dolstra@tudelft.nl";
            ''}
            ${optionalString (n == 3) ''
              services.httpd.extraModules = ["proxy_balancer"];
              services.httpd.extraConfig =
                "
                  <Proxy balancer://cluster>
                    Allow from all
                    BalancerMember http://target2 retry=0
                  </Proxy>
                  ProxyPass        /foo/ balancer://cluster/
                  ProxyPassReverse /foo/ balancer://cluster/
                ";
            ''}
          };

        target2 =
          { config, pkgs, ... }:
          { services.openssh.enable = true;
            users.extraUsers.root.openssh.authorizedKeys.keyFiles = [ ./id_test.pub ];
            ${optionalString (n == 3) ''
              services.httpd.enable = true;
              services.httpd.adminAddr = "e.dolstra@tudelft.nl";
            ''}
          };
      }
    '';

  env = "NIX_PATH=nixos=${<nixos>}:nixpkgs=${<nixpkgs>}";

in

{

  nodes =
    { coordinator =
        { config, pkgs, ... }:
        { environment.systemPackages =
            [ nixops pkgs.stdenv pkgs.vim pkgs.apacheHttpd pkgs.busybox pkgs.module_init_tools ];
          virtualisation.writableStore = true;
        };

      target1 =
        { config, pkgs, ... }:
        { services.openssh.enable = true;
          virtualisation.memorySize = 512;
          virtualisation.writableStore = true;
          users.extraUsers.root.openssh.authorizedKeys.keyFiles = [ ./id_test.pub ];
        };

      target2 =
        { config, pkgs, ... }:
        { services.openssh.enable = true;
          virtualisation.memorySize = 512;
          virtualisation.writableStore = true;
          users.extraUsers.root.openssh.authorizedKeys.keyFiles = [ ./id_test.pub ];
        };
    };

  testScript = { nodes }:
    ''
      # Start all machines.
      startAll;
      $coordinator->waitForJob("network-interfaces.target");
      $target1->waitForJob("sshd");
      $target2->waitForJob("sshd");

      # Test ssh connectivity
      $coordinator->succeed("mkdir -m 0700 -p ~/.ssh; cp ${./id_test} ~/.ssh/id_dsa; chmod 600 ~/.ssh/id_dsa");
      $coordinator->succeed("ssh -o StrictHostKeyChecking=no -v target1 ls / >&2");
      $coordinator->succeed("ssh -o StrictHostKeyChecking=no -v target2 ls / >&2");

      # Test some trivial commands.
      subtest "trivia", sub {
        $coordinator->succeed("nixops --version 2>&1 | grep NixOps");
        $coordinator->succeed("nixops --help");
      };

      # Set up the state file.
      $coordinator->succeed("cp ${physical} physical.nix");
      $coordinator->succeed("cp ${logical 1} logical.nix");
      $coordinator->succeed("cp ${./id_test.pub} id_test.pub");
      $coordinator->succeed("nixops create ./physical.nix ./logical.nix");

      # Test ‘nixops info’.
      subtest "info-before", sub {
        $coordinator->succeed("${env} nixops info >&2");
      };

      # Do a deployment.
      subtest "deploy-1", sub {
        $target1->fail("vim --version");
        $coordinator->succeed("${env} nixops deploy --build-only");
        $coordinator->succeed("${env} nixops deploy");
        $target1->succeed("vim --version >&2");
      };

      # Test ‘nixops info’.
      subtest "info-after", sub {
        $coordinator->succeed("${env} nixops info >&2");
      };

      # Test ‘nixops ssh’.
      subtest "ssh", sub {
        $coordinator->succeed("${env} nixops ssh target1 -- -v ls / >&2");
      };

      # Test ‘nixops check’.
      subtest "check", sub {
        $coordinator->succeed("${env} nixops check");
      };

      # Deploy Apache, remove vim.
      subtest "deploy-2", sub {
        $coordinator->succeed("cp ${logical 2} logical.nix");
        $coordinator->succeed("${env} nixops deploy");
        $target1->fail("vim --version >&2");
        $coordinator->succeed("curl --fail -v http://target1/ >&2");
        $coordinator->fail("curl --fail -v http://target1/foo >&2");
      };

      # Deploy an Apache proxy to target1 and a backend to target2.
      subtest "deploy-3", sub {
        $coordinator->succeed("cp ${logical 3} logical.nix");
        $coordinator->succeed("${env} nixops deploy");
        $target1->waitForJob("httpd");
        $coordinator->succeed("curl --fail -v http://target2/ >&2");
        $coordinator->succeed("curl --fail -v http://target1/foo/ >&2");
      };

    '';

})
