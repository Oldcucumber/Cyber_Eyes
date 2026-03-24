#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def build_subject(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def build_san(common_name: str) -> x509.SubjectAlternativeName:
    names: list[x509.GeneralName] = [x509.DNSName('localhost')]
    try:
        names.append(x509.IPAddress(ipaddress.ip_address('127.0.0.1')))
    except ValueError:
        pass

    try:
        ip = ipaddress.ip_address(common_name)
    except ValueError:
        names.append(x509.DNSName(common_name))
    else:
        names.append(x509.IPAddress(ip))

    return x509.SubjectAlternativeName(names)


def ensure_certificate(cert_path: Path, key_path: Path, common_name: str, days: int) -> None:
    if cert_path.exists() and key_path.exists():
        print(f'[cert] existing certificate found: {cert_path}')
        return

    cert_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.parent.mkdir(parents=True, exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = build_subject(common_name)
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=days))
        .add_extension(build_san(common_name), critical=False)
        .sign(private_key=key, algorithm=hashes.SHA256())
    )

    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    print(f'[cert] generated self-signed certificate: {cert_path}')


def main() -> None:
    parser = argparse.ArgumentParser(description='Ensure a self-signed TLS certificate exists.')
    parser.add_argument('--cert', required=True, help='PEM certificate output path')
    parser.add_argument('--key', required=True, help='PEM private key output path')
    parser.add_argument('--common-name', default='localhost', help='Certificate common name')
    parser.add_argument('--days', type=int, default=365, help='Certificate validity in days')
    args = parser.parse_args()

    ensure_certificate(Path(args.cert), Path(args.key), args.common_name, args.days)


if __name__ == '__main__':
    main()
