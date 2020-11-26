#!/bin/bash

# clone dotfiles repo
git clone --separate-git-dir=$HOME/.dotfiles https://github.com/TheRauch1/dotfiles.git tmpdotfiles

# move out dotfiles and delete temporary folder
rsync --recursive --verbose --exclude '.git' tmpdotfiles/ $HOME/
rm -r tmpdotfiles
