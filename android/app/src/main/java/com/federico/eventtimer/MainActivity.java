package com.federico.eventtimer;

import android.os.Bundle;
import android.view.WindowManager;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // Debe registrarse ANTES de super.onCreate().
        registerPlugin(SecondaryDisplayPlugin.class);
        registerPlugin(OscReceiverPlugin.class);
        registerPlugin(WebServerPlugin.class);
        super.onCreate(savedInstanceState);
        // El controlador no debe apagar la pantalla a mitad de evento.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
}
