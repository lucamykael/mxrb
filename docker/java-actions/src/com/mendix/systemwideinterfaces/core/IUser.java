package com.mendix.systemwideinterfaces.core;

/** The System.User of a session. */
public interface IUser {
	String getName();
	IMendixObject getMendixObject();
}
