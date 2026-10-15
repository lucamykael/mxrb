package com.mendix.systemwideinterfaces.core;

/** The session of the calling user. */
public interface ISession {
	IUser getUser(IContext context);
	String getUserName();
	IMendixIdentifier getUserId();
	boolean isSystemSession();
	IContext createContext();

	/** The Ruby application keeps date and time in UTC. */
	default java.util.TimeZone getTimeZone() {
		return java.util.TimeZone.getTimeZone("UTC");
	}
}
