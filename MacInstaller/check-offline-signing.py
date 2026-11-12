#!/usr/bin/env python3
"""Verify the real signing library with ONE explicitly selected local identity; no Apple login/device writes."""
import argparse,os,pathlib,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('--identity',required=True);parser.add_argument('--bundle-id',required=True)
parser.add_argument('--host-profile',required=True);parser.add_argument('--extension-profile',required=True);parser.add_argument('--payload',required=True)
a=parser.parse_args();root=pathlib.Path(__file__).resolve().parents[1];out=root/'build/installer-check';out.mkdir(exist_ok=True,parents=True)
exporter=root/'build/device/export-signing-identity'
source=root/'scripts/export-signing-identity.swift'
if not exporter.exists() or exporter.stat().st_mtime < source.stat().st_mtime:
 subprocess.run(['swiftc',str(source),'-o',str(exporter)],check=True)
with tempfile.TemporaryDirectory(prefix='iappvm-signing-test-') as temporary:
 setup=pathlib.Path(temporary)/'setup.plist'
 subprocess.run([str(exporter),a.identity,a.bundle_id,str(setup)],check=True)
 env=os.environ.copy();env.update(IAPPVM_OFFLINE_SETUP=str(setup),IAPPVM_OFFLINE_HOST_PROFILE=str(pathlib.Path(a.host_profile).resolve()),IAPPVM_OFFLINE_EXTENSION_PROFILE=str(pathlib.Path(a.extension_profile).resolve()),IAPPVM_OFFLINE_PAYLOAD=str(pathlib.Path(a.payload).resolve()))
 subprocess.run(['cargo','test','--locked','--manifest-path',str(root/'MacInstaller/Backend/Cargo.toml'),'real_profile_signs_complete_payload','--','--ignored'],check=True,env=env)
