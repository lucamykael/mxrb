package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type Date of an object. */
public class MendixDateTime extends MendixObjectMember<java.util.Date> {
	public MendixDateTime(IMendixObject object, String name) {
		super(object, name);
	}

	/** Whether the client shows the date in the user's time zone; the Ruby application keeps UTC. */
	public boolean shouldLocalize() {
		return true;
	}
}
