# **my-awesome-scripts [![Awesome](https://awesome.re/badge-flat.svg)](https://awesome.re)**

Personal repository for my scripts.

## Description

A collection of useful scripts for automation, development, and daily tasks.

## Features

- Easy-to-use scripts
- Well-documented code
- Regular updates

## Scripts
- `power-saver.sh` -- This script provides a power management solution for Linux laptops with four configurable power-saving levels (0=performance, 1=balanced, 2=saver, 3=extreme). It supports both **runtime** configuration (CPU governor, frequency limits, turbo boost, SMT, brightness, USB/PCI power management, SATA link power, WiFi/Bluetooth control) and **permanent** kernel parameters via GRUB. Features include automatic AC/battery detection, suspend/hibernate, status reporting, configuration backup/restore, self-installation to PATH, and dependency management for APT-based systems(Kali, Debian, Ubuntu).
- `mdnb2pdf.sh` -- This script is a Bash utility that converts Markdown files and Jupyter Notebooks into arXiv-compliant PDFs. It features four configurable conversion levels, native support for LaTeX math equations, and persistent configuration management via command-line arguments. The tool includes built-in validation for font embedding and file size limits, it installs necessary dependencies like Pandoc and TeX Live automatically.

## Usage

Clone the repository and run the scripts as needed:

```bash
git clone https://github.com/lof310/my-awesome-scripts.git
cd my-awesome-scripts
