package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type IMendixIdentifier of an object. */
public class MendixObjectReference extends MendixObjectMember<com.mendix.systemwideinterfaces.core.IMendixIdentifier> {
	public MendixObjectReference(IMendixObject object, String name) {
		super(object, name);
	}
}
