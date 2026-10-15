package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;

import mxrb.sidecar.Metadata;

/** A reference of an object to one other object. */
public class MendixObjectReference extends MendixObjectMember<IMendixIdentifier> {
	public MendixObjectReference(IMendixObject object, String name) {
		super(object, name);
	}

	/** Whether both entities store the association. */
	public boolean isBoth() {
		IMetaAssociation association = Metadata.get().association(getName());
		return association != null && association.getOwner() == IMetaAssociation.AssociationOwner.BOTH;
	}
}
