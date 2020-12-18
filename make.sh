#!/bin/bash -x

brew install coreutils
brew ls --versions pkg-config > /dev/null || brew install pkg-config
brew ls --versions libssh2 > /dev/null || brew install libssh2

if [[ ! -h $(brew --prefix)/lib/pkgconfig/openssl.pc ]]; then
    ln -s $(brew --prefix)/opt/openssl@1.1/lib/pkgconfig/openssl.pc $(brew --prefix)/lib/pkgconfig/openssl.pc
fi

if [[ ! -h $(brew --prefix)/lib/pkgconfig/libssl.pc ]]; then
    ln -s $(brew --prefix)/opt/openssl@1.1/lib/pkgconfig/libssl.pc $(brew --prefix)/lib/pkgconfig/libssl.pc
fi

if [[ ! -h $(brew --prefix)/lib/pkgconfig/libcrypto.pc ]]; then
    ln -s $(brew --prefix)/opt/openssl@1.1/lib/pkgconfig/libcrypto.pc $(brew --prefix)/lib/pkgconfig/libcrypto.pc
fi

swift package generate-xcodeproj
