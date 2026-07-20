# Contributing to Mux Prompter

First off, thank you for considering contributing to Mux Prompter!

## How Can I Contribute?

### Reporting Bugs

- **Check for existing issues.**
- **Use a clear and descriptive title.**
- **Describe the exact steps** to reproduce the problem.

### Suggesting Enhancements

- **Make sure it fits the goals** of the project.
- **Detail your idea** clearly.

### Pull Requests

1. **Create a new branch** for your feature or bug fix.
2. **Write clear commit messages.**
3. **Include tests** if possible.
4. **Ensure the test suite passes.**

## Development Setup

1. **Clone the repository.**
2. **Ensure Prerequisites are installed:**
   Ensure you have `fzf` and `jq` installed locally.
3. **Run Tests:**
   You can run the mock test suite using:
   ```bash
   cd tests
   bash test_prompter.sh
   ```
4. **Test with Herdr locally:**
   Link your local repository path directly to your Herdr workspace manager:
   ```bash
   herdr plugin link .
   ```

## License

By contributing, you agree that your contributions will be licensed under the MIT License of the project.
