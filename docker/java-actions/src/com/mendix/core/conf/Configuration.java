package com.mendix.core.conf;

import java.io.File;

/** The parts of the application configuration a Java action may read. */
public interface Configuration {
	String getApplicationRootUrl();
	Object getConstantValue(String name);

	default File getTempPath() {
		return new File(System.getProperty("java.io.tmpdir"));
	}

	default File getResourcesPath() {
		return new File(System.getenv().getOrDefault("MXRB_JAVA_ACTIONS_RESOURCES", "resources")).getAbsoluteFile();
	}

	default boolean isInDevelopment() {
		return false;
	}
}
