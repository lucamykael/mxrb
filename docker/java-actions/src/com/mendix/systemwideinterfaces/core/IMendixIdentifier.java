package com.mendix.systemwideinterfaces.core;

/** The identity of an object. */
public interface IMendixIdentifier {
	String getObjectType();
	long toLong();
	IMendixObject getObject();
}
