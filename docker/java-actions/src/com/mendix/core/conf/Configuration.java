package com.mendix.core.conf;

/** The parts of the application configuration a Java action may read. */
public interface Configuration {
	String getApplicationRootUrl();
	Object getConstantValue(String name);
}
