#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.x509.oid import NameOID


def build_subject(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def build_san(common_name: str) -> x509.SubjectAlternativeName:
    names: list[x509.GeneralName] = [x509.DNSName('localhost')]
    names.append(x509.IPAddress(ipaddress.ip_address('127.0.0.1')))

    try:
        ip = ipaddress.ip_address(common_name)
    except ValueError:
        names.append(x509.DNSName(common_name))
    else:
        names.append(x509.IPAddress(ip))

    return x509.SubjectAlternativeName(names)


def expected_san_tokens(common_name: str) -> set[str]:
    tokens = {'DNS:localhost', 'IP:127.0.0.1'}
    try:
        ip = ipaddress.ip_address(common_name)
    except ValueError:
        tokens.add(f'DNS:{common_name}')
    else:
        tokens.add(f'IP:{ip.compressed}')
    return tokens


def cert_public_key_fingerprint(cert: x509.Certificate) -> bytes:
    return cert.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )


def key_public_key_fingerprint(key) -> bytes:
    return key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )


def cert_is_valid(cert_path: Path, key_path: Path, common_name: str, min_remaining_days: int = 7) -> bool:
    try:
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        key = load_pem_private_key(key_path.read_bytes(), password=None)
    except Exception as exc:
        print(f'[cert] existing certificate is unreadable: {exc}')
        return False

    now = datetime.now(timezone.utc)
    not_after = cert.not_valid_after.replace(tzinfo=timezone.utc)
    if not_after <= now + timedelta(days=min_remaining_days):
        print(f'[cert] existing certificate expires too soon: {not_after.isoformat()}')
        return False

    cn_attr = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    if not cn_attr or cn_attr[0].value != common_name:
        print(f'[cert] common name mismatch, expected {common_name!r}')
        return False

    try:
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    except x509.ExtensionNotFound:
        print('[cert] subjectAltName missing')
        return False

    actual_tokens: set[str] = set()
    for name in san:
        if isinstance(name, x509.DNSName):
            actual_tokens.add(f'DNS:{name.value}')
        elif isinstance(name, x509.IPAddress):
            actual_tokens.add(f'IP:{name.value.compressed}')

    if not expected_san_tokens(common_name).issubset(actual_tokens):
        print('[cert] subjectAltName does not match requested host set')
        return False

    if cert_public_key_fingerprint(cert) != key_public_key_fingerprint(key):
        print('[cert] certificate and key do not match')
        return False

    return True


def ensure_certificate(cert_path: Path, key_path: Path, common_name: str, days: int) -> None:
    if cert_path.exists() and key_path.exists() and cert_is_valid(cert_path, key_path, common_name):
        print(f'[cert] reusing existing certificate: {cert_path}')
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
    parser = argparse.ArgumentParser(description='Ensure a self-signed TLS certificate exists and still matches the requested host.')
    parser.add_argument('--cert', required=True, help='PEM certificate output path')
    parser.add_argument('--key', required=True, help='PEM private key output path')
    parser.add_argument('--common-name', default='localhost', help='Certificate common name')
    parser.add_argument('--days', type=int, default=365, help='Certificate validity in days')
    args = parser.parse_args()

    ensure_certificate(Path(args.cert).expanduser(), Path(args.key).expanduser(), args.common_name, args.days)


if __name__ == '__main__':
    main()
