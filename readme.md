# RPM (Rapid node Package Manager)

- [RPM (Rapid node Package Manager)](#rpm-rapid-node-package-manager)
  - [Get started](#get-started)
    - [Installation](#installation)
      - [Build from source](#build-from-source)
  - [How to use](#how-to-use)
    - [Available Commands](#available-commands)
      - [install](#install)
      - [add](#add)
      - [run](#run)
  - [Examples](#examples)
  - [List of available libraries](#list-of-available-libraries)
  - [Contributing](#contributing)

rpm is a fast and easy-to-use package manager for Node.js. It is built with Rust and aims to provide fast performance for managing your Node.js packages.

## Get started

### Installation

#### Build from source

```bash
git clone https://github.com/nerdchanii/rpm.git
cd rpm
cargo build --release
mkdir -p ~/.rpm
cp target/release/rpm ~/.rpm/rpm
```

Add `~/.rpm` to your shell `PATH`, or run the binary directly as `~/.rpm/rpm`.

## How to use

### Available Commands

#### install

- install packages your needed using package.json

```bash
# ex)
rpm install
```

#### add

```bash
# ex) adding library with latest version
rpm add react
# ex) adding library with specific version
rpm add vite@4.2.0
```

#### run

run command excute your script within package.json

if your package.json

```json
"scripts": {
  "dev": "vite",
  "serve": "node index.js"
  }
```

```sh
# you can excute script
rpm run dev 
rpm run server
```

## Examples

The sample Node project that previously lived in the repository root is available at [`examples/vite-react-typescript-starter`](examples/vite-react-typescript-starter).

## List of available libraries

- React
- React-dom
- vite (but, create vite not surpported now.)
- express
- prettier
- vue
- lodash
- svelte

## Contributing

RPM is an open-source project and we welcome contributions from the community. If you'd like to contribute, we encourage you to fork the GitHub repository, make your changes, and submit a pull request. We appreciate all contributions, big or small, and thank you in advance for your help in making RPM better!
