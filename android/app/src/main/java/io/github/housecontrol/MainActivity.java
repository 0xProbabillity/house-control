package io.github.housecontrol;

import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Bundle;
import android.view.*;
import android.webkit.*;
import android.widget.*;
import java.io.ByteArrayInputStream;
import java.net.URI;

/** The server owns the UI and authentication. There is deliberately no JavaScript bridge. */
public final class MainActivity extends Activity {
    private WebView web;
    private LinearLayout root;
    private TextView status;
    private URI server;
    private boolean failed;
    private ValueCallback<Uri[]> fileChoice;
    private byte[] exportData;
    private long exportUntil;
    private static final int PICK_JSON=10, SAVE_JSON=11;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        // Keep content inside system bars, including Android 15 edge-to-edge enforcement.
        getWindow().getDecorView().setOnApplyWindowInsetsListener((v,insets)->{
            v.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom()); return insets.consumeSystemWindowInsets();
        });
        root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setBackgroundColor(Color.rgb(16,24,32));
        Button settings=new Button(this); settings.setText("House Control · Change server"); settings.setOnClickListener(v->configure()); root.addView(settings);
        status=new TextView(this); status.setTextColor(Color.WHITE); status.setPadding(20,12,20,12); status.setVisibility(View.GONE); root.addView(status);
        web=new WebView(this); root.addView(web,new LinearLayout.LayoutParams(-1,0,1)); setContentView(root);
        WebSettings s=web.getSettings(); s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true); s.setAllowFileAccess(false); s.setAllowContentAccess(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW); s.setSupportMultipleWindows(false); s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setMediaPlaybackRequiresUserGesture(true); s.setGeolocationEnabled(false);
        CookieManager.getInstance().setAcceptCookie(true); CookieManager.getInstance().setAcceptThirdPartyCookies(web,false);
        web.setWebChromeClient(new WebChromeClient(){
            @Override public boolean onShowFileChooser(WebView view,ValueCallback<Uri[]> callback,FileChooserParams params){
                if(fileChoice!=null)fileChoice.onReceiveValue(null);
                fileChoice=callback;
                Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json");
                try{startActivityForResult(pick,PICK_JSON);}catch(ActivityNotFoundException e){fileChoice.onReceiveValue(null);fileChoice=null;showError("No file picker is available on this device.");}
                return true;
            }
        });
        web.setDownloadListener((url,agent,disposition,mime,length)->{
            if(!url.startsWith("blob:") || server==null)return;
            try{if(!ServerAddress.sameOrigin(server,URI.create(url.substring(5))))return;}catch(Exception e){return;}
            exportUntil=android.os.SystemClock.elapsedRealtime()+10000;
            // Download only JSON data created by the current origin. A one-shot navigation
            // returns it without exposing a native JavaScript interface to page frames.
            String literal=org.json.JSONObject.quote(url);
            web.evaluateJavascript("(async()=>{try{const r=await fetch("+literal+");const t=await r.text();if(t.length>4194304)throw Error();JSON.parse(t);location.href='housecontrol-export://json?data='+encodeURIComponent(t)}catch(e){location.href='housecontrol-export://error'}})()",null);
        });
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){
                URI uri; try {uri=URI.create(request.getUrl().toString());} catch(Exception e){return true;}
                if("housecontrol-export".equals(uri.getScheme())){
                    if(request.isForMainFrame() && exportUntil>android.os.SystemClock.elapsedRealtime()){
                        exportUntil=0;
                        try{
                            String text=request.getUrl().getQueryParameter("data");
                            if(text==null || text.length()>4194304)throw new IllegalArgumentException();
                            new org.json.JSONObject(text);
                            exportData=text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                            Intent save=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json").putExtra(Intent.EXTRA_TITLE,"House-Control-plan.json");
                            startActivityForResult(save,SAVE_JSON);
                        }catch(Exception e){exportData=null;showError("Could not export this plan. Try again from the editor.");}
                    }
                    return true;
                }
                if ("housecontrol".equals(uri.getScheme()) && "settings".equals(uri.getHost())) {configure();return true;}
                if(server!=null && ServerAddress.sameOrigin(server,uri)) return false;
                if(request.isForMainFrame() && request.hasGesture() && ("https".equals(uri.getScheme()) || "http".equals(uri.getScheme())) && uri.getUserInfo()==null){
                    try {startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(uri.toString())).addCategory(Intent.CATEGORY_BROWSABLE));}catch(ActivityNotFoundException ignored){}
                }
                return true;
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView v,WebResourceRequest r){
                URI uri;try{uri=URI.create(r.getUrl().toString());}catch(Exception e){return blocked();}
                if(server!=null && ServerAddress.sameOrigin(server,uri))return null;
                return blocked();
            }
            @Override public void onReceivedSslError(WebView v,SslErrorHandler h,SslError e){h.cancel();showError("The server certificate could not be verified. Check HTTPS on your server.");}
            @Override public void onReceivedError(WebView v,WebResourceRequest r,WebResourceError e){if(r.isForMainFrame())showError("Cannot reach your server. Check its address and your Wi-Fi, then tap here to retry.");}
            @Override public void onReceivedHttpError(WebView v,WebResourceRequest r,WebResourceResponse e){if(r.isForMainFrame() && e.getStatusCode()>=400)showError("The server returned an error ("+e.getStatusCode()+"). Tap here to retry.");}
            @Override public void onPageStarted(WebView v,String url,android.graphics.Bitmap icon){failed=false;status.setVisibility(View.GONE);}
            @Override public void onPageFinished(WebView v,String url){CookieManager.getInstance().flush();if(!failed)status.setVisibility(View.GONE);}
        });
        status.setOnClickListener(v->load());
        String saved=getPreferences(MODE_PRIVATE).getString("server",null);
        if(saved!=null){try{server=ServerAddress.parse(saved);load();}catch(Exception ignored){configure();}}else configure();
    }
    private WebResourceResponse blocked(){return new WebResourceResponse("text/plain","UTF-8",403,"Blocked",java.util.Collections.emptyMap(),new ByteArrayInputStream(new byte[0]));}
    private void showError(String text){failed=true;status.setText(text);status.setVisibility(View.VISIBLE);}
    private void load(){if(server!=null)web.loadUrl(server.toString()+"/?platform=android");}
    private void configure(){
        EditText address=new EditText(this); address.setSingleLine(true); address.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);
        address.setHint("https://house.example.com"); if(server!=null)address.setText(server.toString());
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Connect to your House Control server").setMessage("Use HTTPS outside your home. Private-network HTTP sends your session unencrypted over that network.").setView(address).setPositiveButton("Connect",null).setNegativeButton(server==null?"Close":"Cancel",(d,w)->{if(server==null)finish();}).create();
        dialog.setOnShowListener(d->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            try{URI next=ServerAddress.parse(address.getText().toString());
                boolean changed=server==null || !ServerAddress.sameOrigin(server,next);
                server=next;getPreferences(MODE_PRIVATE).edit().putString("server",server.toString()).apply();
                if(changed){exportUntil=0;exportData=null;if(fileChoice!=null){fileChoice.onReceiveValue(null);fileChoice=null;}web.stopLoading();web.clearHistory();web.clearCache(true);WebStorage.getInstance().deleteAllData();CookieManager.getInstance().removeAllCookies(ok->load());}else load();
                dialog.dismiss();
            }catch(IllegalArgumentException e){address.setError(e.getMessage());}
        }));dialog.setCanceledOnTouchOutside(false);dialog.show();
    }
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        Uri uri=result==RESULT_OK && data!=null ? data.getData():null;
        if(request==PICK_JSON && fileChoice!=null){fileChoice.onReceiveValue(uri==null?null:new Uri[]{uri});fileChoice=null;}
        if(request==SAVE_JSON){
            byte[] bytes=exportData;exportData=null;
            if(uri!=null && bytes!=null){
                try(java.io.OutputStream out=getContentResolver().openOutputStream(uri)){
                    if(out==null)throw new java.io.IOException();out.write(bytes);
                    status.setText("Plan exported");status.setVisibility(View.VISIBLE);
                }catch(Exception e){showError("Could not save the plan file. Try exporting again.");}
            }
        }
    }
    @Override public void onBackPressed(){if(web.canGoBack())web.goBack();else super.onBackPressed();}
    @Override protected void onResume(){super.onResume();if(web!=null)web.onResume();}
    @Override protected void onPause(){if(web!=null){CookieManager.getInstance().flush();web.onPause();}super.onPause();}
    @Override protected void onDestroy(){if(fileChoice!=null){fileChoice.onReceiveValue(null);fileChoice=null;}if(web!=null){root.removeView(web);web.stopLoading();web.destroy();web=null;}super.onDestroy();}
}
