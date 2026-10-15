package com.mendix.systemwideinterfaces.core;

/** The System.User of a session; a guest's is anonymous. */
public interface IUser {
	String getName();
	IMendixObject getMendixObject();

	default Boolean isAnonymous() {
		return Boolean.FALSE;
	}
}
