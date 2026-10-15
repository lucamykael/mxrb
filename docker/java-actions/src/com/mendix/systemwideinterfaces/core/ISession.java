package com.mendix.systemwideinterfaces.core;

/** The session of the calling user. */
public interface ISession {
	IUser getUser(IContext context);
	String getUserName();
	IMendixIdentifier getUserId();
	boolean isSystemSession();
	IContext createContext();
}
