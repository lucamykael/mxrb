package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type IMendixIdentifier> of an object. */
public class MendixObjectReferenceSet extends MendixObjectMember<java.util.List<com.mendix.systemwideinterfaces.core.IMendixIdentifier>> {
	public MendixObjectReferenceSet(IMendixObject object, String name) {
		super(object, name);
	}
}
