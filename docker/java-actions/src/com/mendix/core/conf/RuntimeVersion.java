package com.mendix.core.conf;

import mxrb.sidecar.Bridge;

/** The version of the Mendix Runtime the application targets. */
public final class RuntimeVersion {
	private final String version;

	private RuntimeVersion(String version) {
		this.version = version;
	}

	public static RuntimeVersion getInstance() {
		return new RuntimeVersion((String) Bridge.current().call("runtime_version"));
	}

	public int getMajorVersion() {
		return part(0);
	}

	public int getMinorVersion() {
		return part(1);
	}

	public int getPatchVersion() {
		return part(2);
	}

	@Override
	public String toString() {
		return version;
	}

	private int part(int index) {
		String[] parts = version.split("\\.");
		return index < parts.length ? Integer.parseInt(parts[index].replaceAll("\\D.*", "")) : 0;
	}
}
