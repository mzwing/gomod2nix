// Package cmd implements the command line interface for gomod2nix
package cmd

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	generate "github.com/nix-community/gomod2nix/internal/generate"
	schema "github.com/nix-community/gomod2nix/internal/schema"
	"github.com/spf13/cobra"
)

const directoryDefault = "./"

var (
	flagDirectory string
	flagOutDir    string
	maxJobs       int
	flagWithDeps  bool
	flagDebug     bool
)

// configureLogging installs the default slog handler. The log level is
// Debug when --debug is passed, Info otherwise.
func configureLogging() {
	level := slog.LevelInfo
	if flagDebug {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: level,
	})))
}

func generateFunc(cmd *cobra.Command, args []string) error {
	configureLogging()

	directory := flagDirectory
	outDir := flagOutDir

	// If we are dealing with a project packaged by passing packages on the command line
	// we need to create a temporary project.
	var tmpProj *generate.TempProject
	if len(args) > 0 {
		var err error

		if directory != directoryDefault {
			return fmt.Errorf("directory flag not supported together with import arguments")
		}
		if outDir == "" {
			pwd, err := os.Getwd()
			if err != nil {
				return err
			}

			outDir = pwd
		}

		tmpProj, err = generate.NewTempProject(args)
		if err != nil {
			return err
		}
		defer func() {
			if err := tmpProj.Remove(); err != nil {
				slog.Error("Error removing temporary project", "err", err)
			}
		}()

		directory = tmpProj.Dir
	} else if outDir == "" {
		// Default out to current working directory if we are developing some software in the current repo.
		outDir = directory
	}

	// Write gomod2nix.toml
	goMod2NixPath := filepath.Join(outDir, "gomod2nix.toml")
	outFile := goMod2NixPath
	pkgs, err := generate.GeneratePkgs(directory, goMod2NixPath, maxJobs)
	if err != nil {
		return fmt.Errorf("error generating pkgs: %w", err)
	}

	var goPackagePath string
	var subPackages []string

	if tmpProj != nil {
		subPackages = tmpProj.SubPackages
		goPackagePath = tmpProj.GoPackagePath
	}

	var cacheModules map[string]*schema.CacheModule
	if flagWithDeps {
		cacheModules, err = generate.GenerateCacheModules(directory)
		if err != nil {
			return fmt.Errorf("error generating cache modules: %w", err)
		}
	}

	output, err := schema.Marshal(pkgs, goPackagePath, subPackages, cacheModules)
	if err != nil {
		return fmt.Errorf("error marshaling output: %w", err)
	}

	err = os.WriteFile(outFile, output, 0644)
	if err != nil {
		return fmt.Errorf("error writing file: %w", err)
	}
	slog.Info("Wrote output", "file", outFile)

	return nil
}

var rootCmd = &cobra.Command{
	Use:           "gomod2nix",
	Short:         "Convert applications using Go modules -> Nix",
	RunE:          generateFunc,
	SilenceUsage:  true,
	SilenceErrors: true,
}

var generateCmd = &cobra.Command{
	Use:   "generate",
	Short: "Run gomod2nix.toml generator",
	RunE:  generateFunc,
}

var importCmd = &cobra.Command{
	Use:   "import",
	Short: "Import Go sources into the Nix store",
	RunE: func(cmd *cobra.Command, args []string) error {
		configureLogging()
		return generate.ImportPkgs(flagDirectory, maxJobs)
	},
}

func init() {
	rootCmd.PersistentFlags().StringVar(&flagDirectory, "dir", "./", "Go project directory")
	rootCmd.PersistentFlags().StringVar(&flagOutDir, "outdir", "", "Output directory (defaults to project directory)")
	rootCmd.PersistentFlags().IntVar(&maxJobs, "jobs", 10, "Max number of concurrent jobs")
	rootCmd.PersistentFlags().BoolVar(&flagWithDeps, "with-deps", false, "Include dependencies in gomod2nix.toml for per-module build cache priming")
	rootCmd.PersistentFlags().BoolVar(&flagDebug, "debug", false, "Enable debug logging")

	rootCmd.AddCommand(generateCmd)
	rootCmd.AddCommand(importCmd)
}

func Execute() error {
	return rootCmd.Execute()
}
