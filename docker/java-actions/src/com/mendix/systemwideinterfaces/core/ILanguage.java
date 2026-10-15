package com.mendix.systemwideinterfaces.core;

/** A language of the application. */
public interface ILanguage {
	String getCode();
	IMendixObject getMendixObject();

	default boolean isRightToLeft() {
		return false;
	}
}
