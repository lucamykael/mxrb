package com.mendix.core.objectmanagement.member;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;

import com.mendix.core.Core;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** The contents of a file document, kept by the Ruby application. */
public class MendixBinary extends MendixObjectMember<InputStream> {
	private final IMendixObject file;

	public MendixBinary(IMendixObject object, String name) {
		super(object, name);
		this.file = object;
	}

	@Override
	public InputStream getValue(IContext context) {
		return Core.getFileDocumentContent(context, file);
	}

	@Override
	public void setValue(IContext context, InputStream value) {
		Core.storeFileDocumentContent(context, file, value);
	}

	/** Writes the contents to the stream and closes it. */
	public void retrieveValue(IContext context, OutputStream output) {
		try (output; InputStream content = getValue(context)) {
			content.transferTo(output);
		} catch (IOException e) {
			throw new UncheckedIOException(e);
		}
	}

	public void storeValue(IContext context, InputStream input, long length) {
		setValue(context, input);
	}

	@Override
	public boolean isChanged() {
		return false;
	}
}
